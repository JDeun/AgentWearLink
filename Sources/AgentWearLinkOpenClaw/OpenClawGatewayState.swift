import Foundation

public actor OpenClawGatewayState {
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
              policy.tickIntervalMs <= 3_600_000,
              policy.attachments?.maxBytes ?? 1 > 0,
              policy.attachments?.maxImageBytes ?? 1 > 0 else {
            throw AWLOpenClawError.invalidPolicy
        }
    }

    public func acceptHello(_ hello: OpenClawHelloOK) throws {
        try Self.validateHello(hello)
        self.hello = hello
        self.connectionState = .ready
    }

    public func observeSequence(_ sequence: Int?) throws {
        guard let sequence else { return }
        if let lastSequence {
            guard sequence == lastSequence + 1 else {
                throw AWLOpenClawError.sequenceGap(
                    expected: lastSequence + 1,
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
}

public enum AWLOpenClawError: Error, Sendable, Equatable {
    case notReady
    case protocolMismatch
    case invalidPolicy
    case sequenceGap(expected: Int, actual: Int)
    case payloadTooLarge(actual: Int, maximum: Int)
    case gateway(code: String, retryable: Bool, retryAfterMilliseconds: Int? = nil)
    case disconnected
    case deliveryUncertain
}
