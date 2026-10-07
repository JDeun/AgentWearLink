import Foundation

public actor OpenClawGatewayState {
    public static let maximumTickIntervalMilliseconds = 3_600_000

    public private(set) var connectionState: GatewayConnectionState = .disconnected
    public private(set) var hello: OpenClawHelloOK?
    public private(set) var lastSequence: Int?

    public init() {}

    public func beginConnect() {
        connectionState = .connecting
        hello = nil
        lastSequence = nil
    }

    public func beginAuthentication() {
        connectionState = .authenticating
    }

    public static func validateHello(_ hello: OpenClawHelloOK) throws {
        guard hello.type == "hello-ok",
              hello.protocolVersion == OpenClawProtocol.currentVersion else {
            throw AWLOpenClawError.protocolMismatch
        }
        let policy = hello.policy
        guard policy.maxPayload > 0,
              policy.maxBufferedBytes > 0,
              policy.tickIntervalMs > 0,
              policy.tickIntervalMs <= maximumTickIntervalMilliseconds else {
            throw AWLOpenClawError.invalidPolicy
        }

        if let attachments = policy.attachments {
            guard attachments.maxBytes > 0,
                  attachments.maxImageBytes > 0 else {
                throw AWLOpenClawError.invalidPolicy
            }
        }

        if let snapshot = hello.snapshot {
            guard snapshot.uptimeMs >= 0,
                  snapshot.stateVersion.presence >= 0,
                  snapshot.stateVersion.health >= 0 else {
                throw AWLOpenClawError.invalidSnapshot
            }
        }
    }

    public func acceptHello(_ hello: OpenClawHelloOK) throws {
        try Self.validateHello(hello)
        self.hello = hello
        self.connectionState = .ready
    }

    public func observeSequence(_ sequence: Int?) throws {
        guard let sequence else { return }
        guard sequence >= 0 else {
            throw AWLOpenClawError.invalidSequence(sequence)
        }

        if let lastSequence {
            guard lastSequence != Int.max else {
                throw AWLOpenClawError.sequenceExhausted(last: lastSequence)
            }

            let expected = lastSequence + 1
            guard sequence == expected else {
                throw AWLOpenClawError.sequenceGap(
                    expected: expected,
                    actual: sequence
                )
            }
        }
        lastSequence = sequence
    }

    public func beginReconnect(attempt: Int) {
        connectionState = .reconnecting(attempt: attempt)
        hello = nil
        lastSequence = nil
    }

    public func disconnect() {
        connectionState = .disconnected
        hello = nil
        lastSequence = nil
    }

    public func validateOutboundFrameSize(_ bytes: Int) throws {
        guard let policy = hello?.policy else {
            throw AWLOpenClawError.notReady
        }
        guard bytes <= policy.maxPayload else {
            throw AWLOpenClawError.payloadTooLarge(
                actual: bytes,
                maximum: policy.maxPayload
            )
        }
    }

    /// Preflights native agent text + attachments before JSON/base64 allocation.
    ///
    /// The exact encoded frame is still checked by `validateOutboundFrameSize`
    /// after encoding. This earlier guard prevents a raw image that is already
    /// outside negotiated policy from first expanding into a large base64
    /// string.
    public func validateAgentPayload(
        messageUTF8Bytes: Int,
        attachments: [OpenClawAgentAttachment]
    ) throws {
        guard let policy = hello?.policy else {
            throw AWLOpenClawError.notReady
        }
        guard messageUTF8Bytes >= 0 else {
            throw AWLOpenClawError.payloadTooLarge(
                actual: Int.max,
                maximum: policy.maxPayload
            )
        }

        if attachments.isEmpty {
            guard messageUTF8Bytes <= policy.maxPayload else {
                throw AWLOpenClawError.payloadTooLarge(
                    actual: messageUTF8Bytes,
                    maximum: policy.maxPayload
                )
            }
            return
        }

        guard let attachmentPolicy = policy.attachments else {
            throw AWLOpenClawError.attachmentsUnavailable
        }

        var totalRawBytes = 0
        var estimatedPayloadBytes = messageUTF8Bytes

        for attachment in attachments {
            let rawBytes = attachment.rawByteCount
            guard rawBytes > 0 else {
                throw AWLOpenClawError.invalidAttachment
            }
            guard rawBytes <= attachmentPolicy.maxImageBytes else {
                throw AWLOpenClawError.imageAttachmentTooLarge(
                    actual: rawBytes,
                    maximum: attachmentPolicy.maxImageBytes
                )
            }

            let (nextRawBytes, rawOverflow) = totalRawBytes.addingReportingOverflow(rawBytes)
            guard !rawOverflow else {
                throw AWLOpenClawError.attachmentBudgetExceeded(
                    actual: Int.max,
                    maximum: attachmentPolicy.maxBytes
                )
            }
            totalRawBytes = nextRawBytes
            guard totalRawBytes <= attachmentPolicy.maxBytes else {
                throw AWLOpenClawError.attachmentBudgetExceeded(
                    actual: totalRawBytes,
                    maximum: attachmentPolicy.maxBytes
                )
            }

            let encodedBytes = attachment.base64EncodedByteCount
            let (nextEstimatedBytes, payloadOverflow) =
                estimatedPayloadBytes.addingReportingOverflow(encodedBytes)
            guard !payloadOverflow else {
                throw AWLOpenClawError.payloadTooLarge(
                    actual: Int.max,
                    maximum: policy.maxPayload
                )
            }
            estimatedPayloadBytes = nextEstimatedBytes
            guard estimatedPayloadBytes <= policy.maxPayload else {
                throw AWLOpenClawError.payloadTooLarge(
                    actual: estimatedPayloadBytes,
                    maximum: policy.maxPayload
                )
            }
        }
    }

    public func negotiatedMaximumBufferedBytes() throws -> Int {
        guard let policy = hello?.policy else {
            throw AWLOpenClawError.notReady
        }
        return policy.maxBufferedBytes
    }
}

public enum AWLOpenClawError: Error, Sendable, Equatable {
    case notReady
    case protocolMismatch
    case invalidPolicy
    case invalidSnapshot
    case invalidSequence(Int)
    case sequenceExhausted(last: Int)
    case sequenceGap(expected: Int, actual: Int)
    case payloadTooLarge(actual: Int, maximum: Int)
    case attachmentsUnavailable
    case invalidAttachment
    case imageAttachmentTooLarge(actual: Int, maximum: Int)
    case attachmentBudgetExceeded(actual: Int, maximum: Int)
    case bufferBudgetExceeded(actual: Int, maximum: Int)
    case gateway(code: String, retryable: Bool, retryAfterMilliseconds: Int? = nil)
    case disconnected
}
