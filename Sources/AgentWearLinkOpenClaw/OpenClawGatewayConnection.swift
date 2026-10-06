import Foundation

public actor OpenClawGatewayConnection {
    private let socket: any OpenClawWebSocket
    private let state: OpenClawGatewayState
    private let assembler: OpenClawConnectAssembler
    private let frameRouter = OpenClawFrameRouter()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        socket: any OpenClawWebSocket,
        assembler: OpenClawConnectAssembler,
        state: OpenClawGatewayState = .init()
    ) {
        self.socket = socket
        self.assembler = assembler
        self.state = state
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
            let challengeText = try await socket.receive()
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

            let responseText = try await socket.receive()
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
            try OpenClawGatewayState.validateHello(hello)
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
    case challengeRequired
    case invalidChallenge
    case unexpectedConnectResponse
    case missingHello
    case pairingRequired(OpenClawPairingRequired)
}
