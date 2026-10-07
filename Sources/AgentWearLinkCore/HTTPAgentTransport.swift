import Foundation

public struct HTTPAgentTransportConfiguration: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let endpoint: URL
    public let bearerToken: String?
    public let timeout: TimeInterval
    public let maximumRequestBytes: Int
    public let maximumResponseBytes: Int

    public init(
        endpoint: URL,
        bearerToken: String? = nil,
        timeout: TimeInterval = 30,
        maximumRequestBytes: Int = AgentRequest.defaultMaximumTextBytes,
        maximumResponseBytes: Int = 1_048_576
    ) {
        precondition(timeout.isFinite && timeout > 0)
        precondition(maximumRequestBytes > 0)
        precondition(maximumResponseBytes > 0)
        self.endpoint = endpoint
        self.bearerToken = bearerToken
        self.timeout = timeout
        self.maximumRequestBytes = maximumRequestBytes
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
        "maximumRequestBytes: \(maximumRequestBytes), " +
        "maximumResponseBytes: \(maximumResponseBytes))"
    }

    public var debugDescription: String { description }
}

/// Receives an HTTP response incrementally and owns the URLSession task that
/// must be cancelled as soon as the response exceeds its configured ceiling.
final class BoundedHTTPResponseLoader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    typealias Completion = @Sendable (Result<(HTTPURLResponse, Data), Error>) -> Void

    private let maximumResponseBytes: Int
    private let completion: Completion
    private let lock = NSLock()

    private var response: HTTPURLResponse?
    private var buffer = Data()
    private var completed = false
    private var session: URLSession!
    private var task: URLSessionDataTask!

    init(
        configuration: URLSessionConfiguration,
        request: URLRequest,
        maximumResponseBytes: Int,
        completion: @escaping Completion
    ) {
        self.maximumResponseBytes = maximumResponseBytes
        self.completion = completion
        super.init()

        session = URLSession(
            configuration: configuration,
            delegate: self,
            delegateQueue: nil
        )
        task = session.dataTask(with: request)
    }

    func resume() {
        task.resume()
    }

    func cancel() {
        task.cancel()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(.failure(AWLError.transport("non-HTTP response")))
            return
        }

        let expectedLength = http.expectedContentLength
        if expectedLength > Int64(maximumResponseBytes) {
            completionHandler(.cancel)
            finish(.failure(
                AWLError.transport("response exceeds configured byte limit")
            ))
            return
        }

        lock.lock()
        guard !completed else {
            lock.unlock()
            completionHandler(.cancel)
            return
        }
        self.response = http
        if expectedLength > 0 {
            buffer.reserveCapacity(
                min(maximumResponseBytes, Int(expectedLength))
            )
        }
        lock.unlock()

        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        receiveBodyChunk(data) {
            dataTask.cancel()
        }
    }

    /// Applies one body chunk to the bounded accumulator.
    ///
    /// cancelSource is invoked synchronously before terminal completion when
    /// the next chunk would cross the configured ceiling. Keeping this logic
    /// independent from URLSession scheduling makes the memory-bound invariant
    /// deterministic and directly testable.
    func receiveBodyChunk(
        _ data: Data,
        cancelSource: () -> Void
    ) {
        var exceeded = false

        lock.lock()
        if !completed {
            if data.count > maximumResponseBytes - buffer.count {
                exceeded = true
            } else {
                buffer.append(data)
            }
        }
        lock.unlock()

        guard exceeded else { return }

        cancelSource()
        finish(.failure(
            AWLError.transport("response exceeds configured byte limit")
        ))
    }

    func bufferedResponseByteCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return buffer.count
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            finish(.failure(error))
            return
        }

        lock.lock()
        let response = self.response
        let data = buffer
        lock.unlock()

        guard let response else {
            finish(.failure(AWLError.transport("non-HTTP response")))
            return
        }

        finish(.success((response, data)))
    }

    private func finish(
        _ result: Result<(HTTPURLResponse, Data), Error>
    ) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        lock.unlock()

        completion(result)

        // Each loader owns a dedicated one-request URLSession. Terminal
        // completion must invalidate that session even if the task never
        // reached resume() (for example, cancellation during setup). Waiting
        // with finishTasksAndInvalidate() can retain a suspended task and its
        // delegate indefinitely.
        session.invalidateAndCancel()
    }
}

/// Buffered HTTP baseline transport.
///
/// The response is emitted only after the body completes, but memory is bounded
/// during download. A dedicated URLSessionDataDelegate checks each received
/// chunk and cancels the task before buffered response storage can grow beyond
/// `maximumResponseBytes`.
///
/// This type deliberately does not claim conversational streaming semantics.
/// SSE/WebSocket transports are separate implementations of AgentTransport.
public actor HTTPAgentTransport: AgentTransport {
    private struct Operation {
        let generation: UUID
        let loader: BoundedHTTPResponseLoader
        let continuation: AsyncThrowingStream<AgentResponse, Error>.Continuation
    }

    private let configuration: HTTPAgentTransportConfiguration
    private let sessionConfiguration: URLSessionConfiguration
    private var operations: [InteractionID: Operation] = [:]

    public init(
        configuration: HTTPAgentTransportConfiguration,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.sessionConfiguration = session.configuration
    }

    public func connect() async throws {
        try configuration.validateCredentialTransport()
    }

    public func disconnect() async {
        let active = Array(operations.values)
        operations.removeAll(keepingCapacity: false)

        for operation in active {
            operation.loader.cancel()
            operation.continuation.finish(throwing: AWLError.cancelled)
        }
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
            try request.validateMaximumTextBytes(configuration.maximumRequestBytes)
            let body = try JSONEncoder().encode(request)
            guard body.count <= configuration.maximumRequestBytes else {
                throw AgentRequestValidationError.payloadTooLarge(
                    actual: body.count,
                    maximum: configuration.maximumRequestBytes
                )
            }
            urlRequest.httpBody = body
        } catch {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: error)
            }
        }

        let generation = UUID()
        let (stream, continuation) = AsyncThrowingStream<AgentResponse, Error>.makeStream()

        let loader = BoundedHTTPResponseLoader(
            configuration: sessionConfiguration,
            request: urlRequest,
            maximumResponseBytes: configuration.maximumResponseBytes
        ) { result in
            Task {
                await self.complete(
                    result,
                    interactionID: id,
                    generation: generation
                )
            }
        }

        operations[id] = Operation(
            generation: generation,
            loader: loader,
            continuation: continuation
        )

        continuation.onTermination = { _ in
            Task {
                await self.cancel(interactionID: id)
            }
        }

        loader.resume()
        return stream
    }

    private func complete(
        _ result: Result<(HTTPURLResponse, Data), Error>,
        interactionID id: InteractionID,
        generation: UUID
    ) {
        guard let operation = operations[id],
              operation.generation == generation else {
            return
        }
        operations[id] = nil

        switch result {
        case let .failure(error):
            operation.continuation.finish(
                throwing: Self.map(error)
            )

        case let .success((http, data)):
            guard (200..<300).contains(http.statusCode) else {
                let category: AWLError =
                    (http.statusCode == 401 || http.statusCode == 403)
                    ? .authentication
                    : .transport("HTTP \(http.statusCode)")
                operation.continuation.finish(throwing: category)
                return
            }

            guard !data.isEmpty else {
                operation.continuation.finish(
                    throwing: AWLError.agent("empty response")
                )
                return
            }

            guard let text = String(data: data, encoding: .utf8) else {
                operation.continuation.finish(
                    throwing: AWLError.agent("non-UTF8 response")
                )
                return
            }

            operation.continuation.yield(.textDelta(id, text))
            operation.continuation.yield(.completed(id))
            operation.continuation.finish()
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

    public func cancel(interactionID: InteractionID) async {
        guard let operation = operations.removeValue(forKey: interactionID) else {
            return
        }

        operation.loader.cancel()
        operation.continuation.finish(throwing: AWLError.cancelled)
    }

    func operationCount() -> Int {
        operations.count
    }
}
