import Foundation

public actor OpenClawGatewayConnection {
    private let socket: any OpenClawWebSocket
    private let state: OpenClawGatewayState
    private let assembler: OpenClawConnectAssembler
    private let frameRouter = OpenClawFrameRouter()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let handshakeTimeout: Duration

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
        await state.beginConnect()
        await socket.connect()

        do {
            let challengeText = try await receiveHandshakeFrame(
                timeoutError: .challengeTimeout
            )
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

            await state.beginAuthentication()

            let assembled = try await assembler.assemble(
                version: appVersion,
                scopes: scopes,
                credentials: credentials,
                challenge: challenge,
                clientIdentity: clientIdentity,
                locale: locale
            )

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

            try await socket.send(text: requestText)

            let responseText = try await receiveHandshakeFrame(
                timeoutError: .helloTimeout
            )
            let responseFrame = try frameRouter.decodePreAuth(
                Data(responseText.utf8)
            )

            guard case let .response(response) = responseFrame,
                  response.id == requestID else {
                throw OpenClawHandshakeError.unexpectedConnectResponse
            }

            guard response.ok else {
                if let error = response.error,
                   let pairing = OpenClawPairingRequired(error: error) {
                    // Pairing rejection proves the stored device grant is no longer
                    // usable. Cleanup is best effort so Keychain/store failure cannot
                    // mask the authoritative Gateway handshake error.
                    try? await assembler.invalidateStoredCredentialIfUsed(assembled)
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
            try await assembler.persistHello(hello, assembled: assembled)
            try await state.acceptHello(hello)
            return hello
        } catch {
            await socket.close()
            await state.disconnect()
            throw error
        }
    }

    public func disconnect() async {
        await socket.close()
        await state.disconnect()
    }

    private func receiveHandshakeFrame(
        timeoutError: OpenClawHandshakeError
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
                    await socket.close()
                    throw timeoutError
                }

                if let frame = outcome {
                    group.cancelAll()
                    return frame
                }

                // The deadline won. Close the physical transport before leaving
                // the task-group scope so a receive implementation that does not
                // promptly observe Swift task cancellation is still forced to
                // unwind.
                group.cancelAll()
                await socket.close()
                throw timeoutError
            } catch {
                // Outer task cancellation and receive failures must also retire
                // the socket while still inside the group; otherwise the group
                // could wait indefinitely for a blocked receive child.
                group.cancelAll()
                await socket.close()
                throw error
            }
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
    case challengeTimeout
    case helloTimeout
    case challengeRequired
    case invalidChallenge
    case unexpectedConnectResponse
    case missingHello
    case invalidPolicy
    case pairingRequired(OpenClawPairingRequired)
}
