import Foundation

public actor OpenClawGatewayConnection {
    private let socket: any OpenClawWebSocket
    private let state: OpenClawGatewayState
    private let frameRouter = OpenClawFrameRouter()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        socket: any OpenClawWebSocket,
        state: OpenClawGatewayState = .init()
    ) {
        self.socket = socket
        self.state = state
    }

    public func connect(
        appVersion: String,
        auth: OpenClawConnectParams.Auth?
    ) async throws -> OpenClawHelloOK {
        await state.beginConnect()
        await socket.connect()

        do {
            let challengeText = try await socket.receive()
            let challengeData = Data(challengeText.utf8)
            let frame = try frameRouter.decodePreAuth(challengeData)

            guard case let .event(event) = frame,
                  event.event == "connect.challenge",
                  let payload = event.payload else {
                throw OpenClawHandshakeError.challengeRequired
            }

            _ = try decodeChallenge(payload)
            await state.beginAuthentication()

            let requestID = UUID().uuidString
            let params = OpenClawConnectParams(
                version: appVersion,
                auth: auth
            )
            let request = OpenClawRequestFrame(
                id: requestID,
                method: "connect",
                params: params
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
                throw AWLOpenClawError.gateway(
                    code: response.error?.code ?? "UNKNOWN",
                    retryable: response.error?.retryable ?? false
                )
            }

            guard let payload = response.payload else {
                throw OpenClawHandshakeError.missingHello
            }

            let hello = try decodeHello(payload)
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
        let data = try JSONEncoder().encode(value)
        return try decoder.decode(OpenClawConnectChallenge.self, from: data)
    }

    private func decodeHello(_ value: JSONValue) throws -> OpenClawHelloOK {
        let data = try JSONEncoder().encode(value)
        return try decoder.decode(OpenClawHelloOK.self, from: data)
    }
}

public enum OpenClawHandshakeError: Error, Sendable, Equatable {
    case challengeRequired
    case unexpectedConnectResponse
    case missingHello
}
