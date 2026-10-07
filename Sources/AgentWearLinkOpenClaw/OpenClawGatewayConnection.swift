import Foundation

public actor OpenClawGatewayConnection {
    private let socket: any OpenClawWebSocket
    private let state: OpenClawGatewayState
    private let assembler: OpenClawConnectAssembler
    private let frameRouter = OpenClawFrameRouter()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let handshakeTimeout: Duration
    private var nextConnectGeneration: UInt64 = 0
    private var activeConnectGeneration: UInt64?
    private var disconnectInProgress = false

    public init(
        socket: any OpenClawWebSocket,
        assembler: OpenClawConnectAssembler,
        state: OpenClawGatewayState = .init(),
        handshakeTimeout: Duration = .seconds(10)
    ) {
        precondition(handshakeTimeout > .zero)
        self.socket = socket
        self.assembler = assembler
        self.state = state
        self.handshakeTimeout = handshakeTimeout
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
            guard challenge.ts >= 0, !challenge.nonce.isEmpty else {
                throw OpenClawHandshakeError.invalidChallenge
            }

            try ensureActiveConnect(generation)
            await state.beginAuthentication()
            try ensureActiveConnect(generation)

            var assembled = try await assembler.assemble(
                version: appVersion,
                scopes: scopes,
                credentials: credentials,
                challenge: challenge,
                clientIdentity: clientIdentity,
                locale: locale
            )
            try ensureActiveConnect(generation)

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

                let retryAfter = response.error?.retryAfterMs.flatMap {
                    (0...300_000).contains($0) ? $0 : nil
                }
                throw AWLOpenClawError.gateway(
                    code: response.error?.code ?? "UNKNOWN",
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
        try await socket.send(text: requestText)
        try ensureActiveConnect(generation)

        let responseText = try await receiveHandshakeFrame(
            timeoutError: .helloTimeout,
            generation: generation
        )
        try ensureActiveConnect(generation)

        let responseFrame = try frameRouter.decodePreAuth(Data(responseText.utf8))
        guard case let .response(response) = responseFrame,
              response.id == requestID else {
            throw OpenClawHandshakeError.unexpectedConnectResponse
        }
        return response
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
