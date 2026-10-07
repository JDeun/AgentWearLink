import Foundation
import AgentWearLinkCore

enum OpenClawRequestFactory {
    static func makeRequest(
        configuration: OpenClawConfiguration,
        request: AgentRequest
    ) throws -> URLRequest {
        try request.validateMaximumTextBytes(configuration.maximumRequestBytes)

        let endpoint = configuration.baseURL
            .appendingPathComponent("v1")
            .appendingPathComponent("chat")
            .appendingPathComponent("completions")

        var urlRequest = URLRequest(
            url: endpoint,
            timeoutInterval: configuration.timeout
        )
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(
            "Bearer \(configuration.bearerToken)",
            forHTTPHeaderField: "Authorization"
        )
        urlRequest.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )
        urlRequest.setValue(
            "text/event-stream",
            forHTTPHeaderField: "Accept"
        )

        if let sessionKey = configuration.sessionKey {
            urlRequest.setValue(
                sessionKey,
                forHTTPHeaderField: "x-openclaw-session-key"
            )
        }

        if let channel = configuration.messageChannel {
            urlRequest.setValue(
                channel,
                forHTTPHeaderField: "x-openclaw-message-channel"
            )
        }

        let body = OpenClawChatRequest(
            model: configuration.model,
            user: "agentwearlink:\(configuration.conversationID)",
            stream: true,
            messages: [
                .init(role: "user", content: request.text)
            ]
        )
        let encodedBody = try JSONEncoder().encode(body)
        guard encodedBody.count <= configuration.maximumRequestBytes else {
            throw AgentRequestValidationError.payloadTooLarge(
                actual: encodedBody.count,
                maximum: configuration.maximumRequestBytes
            )
        }
        urlRequest.httpBody = encodedBody
        return urlRequest
    }
}
