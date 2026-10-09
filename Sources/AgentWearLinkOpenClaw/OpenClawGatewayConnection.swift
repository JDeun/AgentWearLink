import Foundation

/// Fixed, non-sensitive milestones for opt-in development Gateway diagnostics.
public enum OpenClawHandshakeProgress: String, Sendable {
    case socketOpened = "socket-opened"
    case challengeReceived = "challenge-received"
    case assembleStarted = "assemble-started"
    case assembleComplete = "assemble-complete"
    case connectSending = "connect-sending"
    case connectSent = "connect-sent"
    case responseReceived = "response-received"
    case gatewayNotPairedUnstructured = "gateway-not-paired-unstructured"
    case gatewayVerifiedUserRequired = "gateway-verified-user-required"
    case gatewayDeviceProofRejected = "gateway-device-proof-rejected"
    case gatewaySharedAuthRejected = "gateway-shared-auth-rejected"
    case gatewayInvalidRequest = "gateway-invalid-request"
    case gatewayUnavailable = "gateway-unavailable"
    case gatewayStartupPending = "gateway-startup-pending"
    case gatewayProfileUnavailable = "gateway-profile-unavailable"
    case gatewayAuthDenied = "gateway-auth-denied"
    case gatewayUnrecognized = "gateway-unrecognized"
}

public actor OpenClawGatewayConnection {
    private let socket: any OpenClawWebSocket
    private let state: OpenClawGatewayState
    private let assembler: OpenClawConnectAssembler
    private let frameRouter = OpenClawFrameRouter()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let handshakeTimeout: Duration
    private let progress: (@Sendable (OpenClawHandshakeProgress) -> Void)?
    private var nextConnectGeneration: UInt64 = 0
    private var activeConnectGeneration: UInt64?
    private var disconnectInProgress = false

    public init(
        socket: any OpenClawWebSocket,
        assembler: OpenClawConnectAssembler,
        state: OpenClawGatewayState = .init(),
        handshakeTimeout: Duration = .seconds(10),
        progress: (@Sendable (OpenClawHandshakeProgress) -> Void)? = nil
    ) {
        precondition(handshakeTimeout > .zero)
        self.socket = socket
        self.assembler = assembler
        self.state = state
        self.handshakeTimeout = handshakeTimeout
        self.progress = progress
    }

    public func connect(
        appVersion: String,
        scopes: [String] = ["operator.read", "operator.write"],
        credentials: OpenClawConnectCredentials = .init(),
        clientIdentity: OpenClawGatewayClientIdentity = .backend,
        locale: String = "en-US"
    ) async throws -> OpenClawHelloOK {
        guard activeConnectGeneration == nil, !disconnectInProgress else {
            throw OpenClawHandshakeError.connectInProgress
        }

        nextConnectGeneration &+= 1
        let generation = nextConnectGeneration
        activeConnectGeneration = generation

        await state.beginConnect()
        await socket.connect()
        progress?(.socketOpened)

        do {
            try ensureActiveConnect(generation)

            let challengeText = try await receiveHandshakeFrame(
                timeoutError: .challengeTimeout,
                generation: generation
            )
            try ensureActiveConnect(generation)

            let frame = try frameRouter.decodePreAuth(Data(challengeText.utf8))

            guard case let .event(event) = frame,
                  event.event == "connect.challenge",
                  let payload = event.payload else {
                throw OpenClawHandshakeError.challengeRequired
            }

            let challenge = try decodeChallenge(payload)
            progress?(.challengeReceived)
            guard challenge.ts >= 0, !challenge.nonce.isEmpty else {
                throw OpenClawHandshakeError.invalidChallenge
            }

            try ensureActiveConnect(generation)
            await state.beginAuthentication()
            try ensureActiveConnect(generation)

            progress?(.assembleStarted)
            var assembled = try await assembler.assemble(
                version: appVersion,
                scopes: scopes,
                credentials: credentials,
                challenge: challenge,
                clientIdentity: clientIdentity,
                locale: locale
            )
            try ensureActiveConnect(generation)
            progress?(.assembleComplete)

            var response = try await sendConnectRequest(
                assembled,
                generation: generation
            )

            if !response.ok,
               let error = response.error,
               OpenClawDeviceTokenRetryHint(error: error) != nil,
               !assembled.usedStoredCredential,
               let retryAssembly = try await assembler.assembleStoredDeviceTokenRetry(
                   version: appVersion,
                   challenge: challenge,
                   clientIdentity: clientIdentity,
                   locale: locale
               ) {
                try ensureActiveConnect(generation)
                assembled = retryAssembly
                response = try await sendConnectRequest(
                    retryAssembly,
                    generation: generation
                )
            }

            guard response.ok else {
                if let error = response.error,
                   let pairing = OpenClawPairingRequired(error: error) {
                    try ensureActiveConnect(generation)
                    // Pairing rejection proves the stored device grant is no longer
                    // usable. Cleanup is best effort so Keychain/store failure cannot
                    // mask the authoritative Gateway handshake error.
                    try? await assembler.invalidateStoredCredentialIfUsed(assembled)
                    try ensureActiveConnect(generation)
                    throw OpenClawHandshakeError.pairingRequired(pairing)
                }

                if let error = response.error {
                    // Only fixed categories cross the diagnostic boundary.
                    // Never surface raw Gateway codes, messages or identifiers.
                    progress?(Self.classifyGatewayRejection(error))
                }

                let retryAfter = response.error?.retryAfterMs.flatMap {
                    (0...300_000).contains($0) ? $0 : nil
                }
                throw AWLOpenClawError.gateway(
                    code: OpenClawGatewayErrorCodePolicy.safeCode(response.error?.code),
                    retryable: response.error?.retryable ?? false,
                    retryAfterMilliseconds: retryAfter
                )
            }

            guard let payload = response.payload else {
                throw OpenClawHandshakeError.missingHello
            }

            let hello = try decodeHello(payload)
            do {
                try OpenClawGatewayState.validateHello(hello)
            } catch let error as AWLOpenClawError {
                guard error == .invalidPolicy else { throw error }
                throw OpenClawHandshakeError.invalidPolicy
            }

            // Persistent mutation and ready publication are both fenced by the
            // same owned handshake generation. A disconnect/cancellation that
            // wins before either boundary makes the stale connect fail closed.
            try ensureActiveConnect(generation)
            try await assembler.persistHello(hello, assembled: assembled)
            try ensureActiveConnect(generation)
            try await state.acceptHello(hello)
            try ensureActiveConnect(generation)

            activeConnectGeneration = nil
            return hello
        } catch {
            if activeConnectGeneration == generation {
                // Keep ownership until cleanup completes. That prevents a new
                // connect from entering while this failure is still closing the
                // shared physical socket/state.
                await socket.close()
                await state.disconnect()
                if activeConnectGeneration == generation {
                    activeConnectGeneration = nil
                }
            }
            throw error
        }
    }

    public func disconnect() async {
        disconnectInProgress = true
        nextConnectGeneration &+= 1
        activeConnectGeneration = nil

        await socket.close()
        await state.disconnect()

        disconnectInProgress = false
    }

    private func ensureActiveConnect(_ generation: UInt64) throws {
        try Task.checkCancellation()
        guard activeConnectGeneration == generation, !disconnectInProgress else {
            throw OpenClawHandshakeError.connectInvalidated
        }
    }

    private func receiveHandshakeFrame(
        timeoutError: OpenClawHandshakeError,
        generation: UInt64
    ) async throws -> String {
        let socket = self.socket
        let timeout = handshakeTimeout

        return try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask {
                try await socket.receive()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return nil
            }

            do {
                guard let outcome = try await group.next() else {
                    if activeConnectGeneration == generation {
                        await socket.close()
                    }
                    throw timeoutError
                }

                try ensureActiveConnect(generation)

                if let frame = outcome {
                    group.cancelAll()
                    return frame
                }

                // The deadline won. Close the physical transport only while
                // this handshake still owns it. A stale timeout must never
                // retire a newer connection.
                group.cancelAll()
                if activeConnectGeneration == generation {
                    await socket.close()
                }
                throw timeoutError
            } catch {
                group.cancelAll()
                if activeConnectGeneration == generation {
                    await socket.close()
                }
                throw error
            }
        }
    }


    private func sendConnectRequest(
        _ assembled: OpenClawAssembledConnect,
        generation: UInt64
    ) async throws -> OpenClawResponseEnvelope {
        let requestID = UUID().uuidString
        let request = OpenClawRequestFrame(
            id: requestID,
            method: "connect",
            params: assembled.params
        )
        let requestData = try encoder.encode(request)

        guard requestData.count <= OpenClawProtocol.preAuthMaximumBytes else {
            throw OpenClawFrameError.oversizedPreAuthFrame(
                actual: requestData.count,
                maximum: OpenClawProtocol.preAuthMaximumBytes
            )
        }
        guard let requestText = String(data: requestData, encoding: .utf8) else {
            throw OpenClawFrameError.malformedFrame
        }

        try ensureActiveConnect(generation)
        progress?(.connectSending)
        try await socket.send(text: requestText)
        progress?(.connectSent)
        try ensureActiveConnect(generation)

        let responseText = try await receiveHandshakeFrame(
            timeoutError: .helloTimeout,
            generation: generation
        )
        try ensureActiveConnect(generation)

        let responseFrame = try frameRouter.decodePreAuth(Data(responseText.utf8))
        progress?(.responseReceived)
        guard case let .response(response) = responseFrame,
              response.id == requestID else {
            throw OpenClawHandshakeError.unexpectedConnectResponse
        }
        return response
    }

    static func classifyGatewayRejection(
        _ error: OpenClawResponseEnvelope.GatewayError
    ) -> OpenClawHandshakeProgress {
        let detailCode: String? = {
            guard case let .object(details)? = error.details,
                  case let .string(code)? = details["code"] else { return nil }
            return code
        }()

        // Pinned upstream startup-unavailable.ts provides a precise retry
        // discriminator; generic UNAVAILABLE may indicate a real policy error
        // and must never be retried or accepted as pairing evidence.
        if error.code == "UNAVAILABLE",
           error.retryable == true,
           case let .object(details)? = error.details,
           case let .string(reason)? = details["reason"],
           reason == "startup-sidecars" {
            return .gatewayStartupPending
        }

        switch detailCode {
        case "AUTH_VERIFIED_USER_REQUIRED":
            return .gatewayVerifiedUserRequired
        case "DEVICE_AUTH_INVALID", "DEVICE_AUTH_SIGNATURE_INVALID",
             "DEVICE_AUTH_NONCE_MISMATCH", "DEVICE_AUTH_NONCE_REQUIRED",
             "DEVICE_AUTH_DEVICE_ID_MISMATCH", "DEVICE_AUTH_PUBLIC_KEY_INVALID",
             "DEVICE_AUTH_SIGNATURE_EXPIRED":
            return .gatewayDeviceProofRejected
        case "AUTH_TOKEN_MISSING", "AUTH_TOKEN_MISMATCH",
             "AUTH_TOKEN_NOT_CONFIGURED", "AUTH_REQUIRED", "AUTH_UNAUTHORIZED":
            return .gatewaySharedAuthRejected
        case "AUTHENTICATED_PROFILE_UNAVAILABLE":
            return .gatewayProfileUnavailable
        default: break
        }
        switch error.code {
        case "NOT_PAIRED":
            // A genuine pairing rejection has authoritative
            // details.code=PAIRING_REQUIRED, parsed before this branch.
            return .gatewayNotPairedUnstructured
        case "INVALID_REQUEST": return .gatewayInvalidRequest
        case "UNAVAILABLE": return .gatewayUnavailable
        case "AUTH_FAILED", "UNAUTHORIZED", "FORBIDDEN":
            return .gatewayAuthDenied
        default: return .gatewayUnrecognized
        }
    }

    private func decodeChallenge(
        _ value: JSONValue
    ) throws -> OpenClawConnectChallenge {
        let data = try encoder.encode(value)
        return try decoder.decode(OpenClawConnectChallenge.self, from: data)
    }

    private func decodeHello(_ value: JSONValue) throws -> OpenClawHelloOK {
        let data = try encoder.encode(value)
        return try decoder.decode(OpenClawHelloOK.self, from: data)
    }
}

public enum OpenClawHandshakeError: Error, Sendable, Equatable {
    case connectInProgress
    case connectInvalidated
    case challengeTimeout
    case helloTimeout
    case challengeRequired
    case invalidChallenge
    case unexpectedConnectResponse
    case missingHello
    case invalidPolicy
    case pairingRequired(OpenClawPairingRequired)
}
