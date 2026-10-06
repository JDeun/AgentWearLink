import Foundation

public struct HTTPAgentTransportConfiguration: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
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
    public var description: String {
        "HTTPAgentTransportConfiguration(" +
        "endpoint: \(endpoint), " +
        "bearerToken: \(bearerToken == nil ? "nil" : "<redacted>"), " +
        "timeout: \(timeout), " +
        "maximumResponseBytes: \(maximumResponseBytes))"
    }

    public var debugDescription: String { description }
}

/// Buffered HTTP baseline transport.
///
/// This type deliberately does not claim streaming semantics. SSE/WebSocket
/// transports are separate implementations of AgentTransport.
public actor HTTPAgentTransport: AgentTransport {
    private enum OperationPhase {
        case registering
        case running(URLSessionDataTask)
        case cancelled
    }

    private struct Operation {
        let generation: UUID
        var phase: OperationPhase
    }

    private let configuration: HTTPAgentTransportConfiguration
    private let session: URLSession
    private var operations: [InteractionID: Operation] = [:]

    public init(
        configuration: HTTPAgentTransportConfiguration,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.session = session
    }

    public func connect() async throws {}

    public func disconnect() async {
        for operation in operations.values {
            if case let .running(task) = operation.phase {
                task.cancel()
            }
        }
        operations.removeAll(keepingCapacity: false)
    }

    public func send(
        _ request: AgentRequest
    ) async -> AsyncThrowingStream<AgentResponse, Error> {
        let id = request.interactionID

        guard operations[id] == nil else {
            return AsyncThrowingStream { continuation in
                continuation.finish(
                    throwing: AWLError.transport("duplicate interaction ID")
                )
            }
        }

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
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: error)
            }
        }

        let generation = UUID()
        operations[id] = Operation(
            generation: generation,
            phase: .registering
        )

        let configuration = self.configuration
        let session = self.session

        return AsyncThrowingStream { continuation in
            let task = session.dataTask(with: urlRequest) { data, response, error in
                defer {
                    Task {
                        await self.finish(id, generation: generation)
                    }
                }

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
                        throwing: AWLError.transport(
                            "response exceeds configured byte limit"
                        )
                    )
                    return
                }

                guard let text = String(data: data, encoding: .utf8) else {
                    continuation.finish(
                        throwing: AWLError.agent("non-UTF8 response")
                    )
                    return
                }

                continuation.yield(.textDelta(id, text))
                continuation.yield(.completed(id))
                continuation.finish()
            }

            continuation.onTermination = { _ in
                Task {
                    await self.cancel(interactionID: id)
                }
            }

            Task {
                let shouldStart = await self.register(
                    task,
                    for: id,
                    generation: generation
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
        for id: InteractionID,
        generation: UUID
    ) -> Bool {
        guard var operation = operations[id],
              operation.generation == generation else {
            return false
        }

        switch operation.phase {
        case .registering:
            operation.phase = .running(task)
            operations[id] = operation
            return true

        case .cancelled:
            operations[id] = nil
            return false

        case .running:
            return false
        }
    }

    private func finish(_ id: InteractionID, generation: UUID) {
        guard operations[id]?.generation == generation else { return }
        operations[id] = nil
    }

    public func cancel(interactionID: InteractionID) async {
        guard var operation = operations[interactionID] else {
            return
        }

        switch operation.phase {
        case .registering:
            operation.phase = .cancelled
            operations[interactionID] = operation

        case let .running(task):
            operations[interactionID] = nil
            task.cancel()

        case .cancelled:
            break
        }
    }

    func operationCount() -> Int {
        operations.count
    }
}
