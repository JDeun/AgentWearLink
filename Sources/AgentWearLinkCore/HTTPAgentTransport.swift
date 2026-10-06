import Foundation

public struct HTTPAgentTransportConfiguration: Sendable, Equatable {
    public let endpoint: URL
    public let bearerToken: String?
    public let timeout: TimeInterval

    public init(endpoint: URL, bearerToken: String? = nil, timeout: TimeInterval = 30) {
        self.endpoint = endpoint
        self.bearerToken = bearerToken
        self.timeout = timeout
    }
}

/// Minimal generic HTTP transport.
///
/// This is intentionally not named OpenClaw: a compatible gateway can adapt
/// its request/response contract at the edge without changing AWL Core.
public actor HTTPAgentTransport: AgentAdapter {
    private let configuration: HTTPAgentTransportConfiguration
    private let session: URLSession
    private var tasks: [InteractionID: URLSessionDataTask] = [:]

    public init(
        configuration: HTTPAgentTransportConfiguration,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.session = session
    }

    public func connect() async throws {}
    public func disconnect() async {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
    }

    public func responses(
        for request: AgentRequest
    ) -> AsyncThrowingStream<AgentResponse, Error> {
        let configuration = self.configuration
        let session = self.session

        return AsyncThrowingStream { continuation in
            var urlRequest = URLRequest(
                url: configuration.endpoint,
                timeoutInterval: configuration.timeout
            )
            urlRequest.httpMethod = "POST"
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let token = configuration.bearerToken {
                urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }

            do {
                urlRequest.httpBody = try JSONEncoder().encode(request)
            } catch {
                continuation.finish(throwing: error)
                return
            }

            let task = session.dataTask(with: urlRequest) { data, response, error in
                if let error {
                    continuation.finish(throwing: error)
                    return
                }

                guard let http = response as? HTTPURLResponse else {
                    continuation.finish(throwing: AWLError.transport("non-HTTP response"))
                    return
                }

                guard (200..<300).contains(http.statusCode) else {
                    let category: AWLError = (http.statusCode == 401 || http.statusCode == 403)
                        ? .authentication
                        : .transport("HTTP \(http.statusCode)")
                    continuation.finish(throwing: category)
                    return
                }

                guard let data,
                      let text = String(data: data, encoding: .utf8) else {
                    continuation.finish(throwing: AWLError.agent("empty or non-UTF8 response"))
                    return
                }

                continuation.yield(.textDelta(request.interactionID, text))
                continuation.yield(.completed(request.interactionID))
                continuation.finish()
            }

            Task { await self.store(task, for: request.interactionID) }
            continuation.onTermination = { _ in task.cancel() }
            task.resume()
        }
    }

    private func store(_ task: URLSessionDataTask, for id: InteractionID) {
        tasks[id]?.cancel()
        tasks[id] = task
    }

    public func cancel(interactionID: InteractionID) async {
        tasks[interactionID]?.cancel()
        tasks[interactionID] = nil
    }
}
