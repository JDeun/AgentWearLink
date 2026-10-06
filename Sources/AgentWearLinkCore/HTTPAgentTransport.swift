import Foundation

public struct HTTPAgentTransportConfiguration: Sendable, Equatable {
    public let endpoint: URL
    public let bearerToken: String?
    public let timeout: TimeInterval
    public let maximumResponseBytes: Int

    public init(
        endpoint: URL,
        bearerToken: String? = nil,
        timeout: TimeInterval = 30,
        maximumResponseBytes: Int = 1_048_576
    ) {
        precondition(maximumResponseBytes > 0)
        self.endpoint = endpoint
        self.bearerToken = bearerToken
        self.timeout = timeout
        self.maximumResponseBytes = maximumResponseBytes
    }
}

/// Buffered HTTP baseline transport.
///
/// This type deliberately does not claim streaming semantics. SSE/WebSocket
/// transports are separate implementations of AgentTransport.
public actor HTTPAgentTransport: AgentTransport {
    private let configuration: HTTPAgentTransportConfiguration
    private let session: URLSession
    private var tasks: [InteractionID: URLSessionDataTask] = [:]
    private var pendingCancellations: Set<InteractionID> = []

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

    public func send(
        _ request: AgentRequest
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
            urlRequest.setValue("application/json, text/plain", forHTTPHeaderField: "Accept")

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
                defer { Task { await self.finish(request.interactionID) } }

                if let error {
                    let nsError = error as NSError
                    if nsError.domain == NSURLErrorDomain &&
                        nsError.code == NSURLErrorCancelled {
                        continuation.finish(throwing: AWLError.cancelled)
                    } else if nsError.domain == NSURLErrorDomain &&
                                nsError.code == NSURLErrorTimedOut {
                        continuation.finish(throwing: AWLError.timeout)
                    } else {
                        continuation.finish(
                            throwing: AWLError.transport(error.localizedDescription)
                        )
                    }
                    return
                }

                guard let http = response as? HTTPURLResponse else {
                    continuation.finish(
                        throwing: AWLError.transport("non-HTTP response")
                    )
                    return
                }

                guard (200..<300).contains(http.statusCode) else {
                    let category: AWLError =
                        (http.statusCode == 401 || http.statusCode == 403)
                        ? .authentication
                        : .transport("HTTP \(http.statusCode)")
                    continuation.finish(throwing: category)
                    return
                }

                guard let data else {
                    continuation.finish(
                        throwing: AWLError.agent("empty response")
                    )
                    return
                }

                guard data.count <= configuration.maximumResponseBytes else {
                    continuation.finish(
                        throwing: AWLError.transport("response exceeds configured byte limit")
                    )
                    return
                }

                guard let text = String(data: data, encoding: .utf8) else {
                    continuation.finish(
                        throwing: AWLError.agent("non-UTF8 response")
                    )
                    return
                }

                continuation.yield(.textDelta(request.interactionID, text))
                continuation.yield(.completed(request.interactionID))
                continuation.finish()
            }

            continuation.onTermination = { _ in task.cancel() }

            Task {
                let shouldStart = await self.register(
                    task,
                    for: request.interactionID
                )
                if shouldStart {
                    task.resume()
                } else {
                    task.cancel()
                }
            }
        }
    }

    private func register(
        _ task: URLSessionDataTask,
        for id: InteractionID
    ) -> Bool {
        if pendingCancellations.remove(id) != nil {
            return false
        }
        guard tasks[id] == nil else { return false }
        tasks[id] = task
        return true
    }

    private func finish(_ id: InteractionID) {
        tasks[id] = nil
    }

    public func cancel(interactionID: InteractionID) async {
        if let task = tasks.removeValue(forKey: interactionID) {
            task.cancel()
        } else {
            // Covers cancellation racing with asynchronous task registration.
            pendingCancellations.insert(interactionID)
        }
    }
}
