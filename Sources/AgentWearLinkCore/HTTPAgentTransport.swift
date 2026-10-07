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
        precondition(timeout.isFinite && timeout > 0)
        precondition(maximumResponseBytes > 0)
        self.endpoint = endpoint
        self.bearerToken = bearerToken
        self.timeout = timeout
        self.maximumResponseBytes = maximumResponseBytes
    }

    public func validateCredentialTransport() throws {
        guard bearerToken != nil else { return }
        if endpoint.scheme?.lowercased() == "https" { return }
        guard endpoint.scheme?.lowercased() == "http",
              let host = endpoint.host?.lowercased(),
              ["localhost", "127.0.0.1", "::1"].contains(host) else {
            throw AWLError.transport("bearer credentials require HTTPS or an explicit loopback HTTP endpoint")
        }
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
/// The response is buffered only up to `maximumResponseBytes`. The transport
/// consumes URLSession's async byte stream and stops the request as soon as the
/// configured ceiling is exceeded rather than allowing Foundation to buffer an
/// unbounded response first.
///
/// This type deliberately does not claim conversational streaming semantics.
/// SSE/WebSocket transports are separate implementations of AgentTransport.
public actor HTTPAgentTransport: AgentTransport {
    private struct Operation {
        let generation: UUID
        let task: Task<Void, Never>
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

    public func connect() async throws {
        try configuration.validateCredentialTransport()
    }

    public func disconnect() async {
        for operation in operations.values {
            operation.task.cancel()
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
        let (stream, continuation) = AsyncThrowingStream<AgentResponse, Error>.makeStream()

        continuation.onTermination = { _ in
            Task {
                await self.cancel(interactionID: id)
            }
        }

        let session = self.session
        let configuration = self.configuration
        let task = Task {
            await self.performRequest(
                urlRequest,
                interactionID: id,
                generation: generation,
                session: session,
                configuration: configuration,
                continuation: continuation
            )
        }

        // The request task must hop back onto this actor before it can enter
        // performRequest(), so the operation is registered before any response
        // can be emitted or cleaned up.
        operations[id] = Operation(
            generation: generation,
            task: task
        )

        return stream
    }

    private func performRequest(
        _ request: URLRequest,
        interactionID id: InteractionID,
        generation: UUID,
        session: URLSession,
        configuration: HTTPAgentTransportConfiguration,
        continuation: AsyncThrowingStream<AgentResponse, Error>.Continuation
    ) async {
        do {
            try Task.checkCancellation()

            let (bytes, response) = try await session.bytes(for: request)
            guard isCurrent(id, generation: generation) else { return }

            guard let http = response as? HTTPURLResponse else {
                throw AWLError.transport("non-HTTP response")
            }

            guard (200..<300).contains(http.statusCode) else {
                if http.statusCode == 401 || http.statusCode == 403 {
                    throw AWLError.authentication
                }
                throw AWLError.transport("HTTP \(http.statusCode)")
            }

            let maximumResponseBytes = configuration.maximumResponseBytes
            let expectedLength = http.expectedContentLength
            if expectedLength > Int64(maximumResponseBytes) {
                throw AWLError.transport(
                    "response exceeds configured byte limit"
                )
            }

            var data = Data()
            if expectedLength > 0 {
                data.reserveCapacity(
                    min(maximumResponseBytes, Int(expectedLength))
                )
            }

            for try await byte in bytes {
                try Task.checkCancellation()
                guard isCurrent(id, generation: generation) else { return }

                // Check before append so resident response storage never grows
                // past the configured ceiling.
                guard data.count < maximumResponseBytes else {
                    throw AWLError.transport(
                        "response exceeds configured byte limit"
                    )
                }
                data.append(byte)
            }

            guard isCurrent(id, generation: generation) else { return }
            guard !data.isEmpty else {
                throw AWLError.agent("empty response")
            }
            guard let text = String(data: data, encoding: .utf8) else {
                throw AWLError.agent("non-UTF8 response")
            }

            // Retire the operation before finishing the stream so the
            // continuation's termination callback cannot race a completed task.
            finish(id, generation: generation)
            continuation.yield(.textDelta(id, text))
            continuation.yield(.completed(id))
            continuation.finish()
        } catch {
            finish(id, generation: generation)
            continuation.finish(throwing: Self.map(error))
        }
    }

    private static func map(_ error: Error) -> Error {
        if let error = error as? AWLError {
            return error
        }
        if error is CancellationError {
            return AWLError.cancelled
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain &&
            nsError.code == NSURLErrorCancelled {
            return AWLError.cancelled
        }
        if nsError.domain == NSURLErrorDomain &&
            nsError.code == NSURLErrorTimedOut {
            return AWLError.timeout
        }
        return AWLError.transport(error.localizedDescription)
    }

    private func isCurrent(
        _ id: InteractionID,
        generation: UUID
    ) -> Bool {
        operations[id]?.generation == generation
    }

    private func finish(_ id: InteractionID, generation: UUID) {
        guard operations[id]?.generation == generation else { return }
        operations[id] = nil
    }

    public func cancel(interactionID: InteractionID) async {
        guard let operation = operations.removeValue(forKey: interactionID) else {
            return
        }
        operation.task.cancel()
    }

    func operationCount() -> Int {
        operations.count
    }
}
