import Foundation
import AgentWearLinkCore

public actor OpenClawChatCompletionsAdapter: AgentAdapter {
    private let configuration: OpenClawConfiguration
    private let session: URLSession
    private var tasks: [InteractionID: Task<Void, Never>] = [:]

    public init(
        configuration: OpenClawConfiguration,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.session = session
    }

    public func connect() async throws {}

    public func disconnect() async {
        let active = tasks.values
        tasks.removeAll()
        active.forEach { $0.cancel() }
    }

    public func responses(
        for request: AgentRequest
    ) async -> AsyncThrowingStream<AgentResponse, Error> {
        let configuration = self.configuration
        let session = self.session

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let urlRequest = try OpenClawRequestFactory.makeRequest(
                        configuration: configuration,
                        request: request
                    )
                    let (bytes, response) = try await session.bytes(for: urlRequest)

                    guard let http = response as? HTTPURLResponse else {
                        throw AWLError.transport("non-HTTP response")
                    }

                    guard (200..<300).contains(http.statusCode) else {
                        if http.statusCode == 401 || http.statusCode == 403 {
                            throw AWLError.authentication
                        }
                        throw AWLError.transport("HTTP \(http.statusCode)")
                    }

                    var emittedCompletion = false

                    for try await line in bytes.lines {
                        try Task.checkCancellation()

                        switch try OpenClawSSEParser.parse(
                            line: line,
                            maximumEventBytes: configuration.maximumEventBytes
                        ) {
                        case let .delta(text):
                            continuation.yield(
                                .textDelta(request.interactionID, text)
                            )

                        case .done:
                            if !emittedCompletion {
                                emittedCompletion = true
                                continuation.yield(
                                    .completed(request.interactionID)
                                )
                            }

                        case .ignored:
                            break
                        }
                    }

                    if !emittedCompletion {
                        continuation.yield(
                            .completed(request.interactionID)
                        )
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: AWLError.cancelled)
                } catch let error as AWLError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(
                        throwing: AWLError.transport(error.localizedDescription)
                    )
                }

                self.finish(request.interactionID)
            }

            Task { self.install(task, for: request.interactionID) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func install(
        _ task: Task<Void, Never>,
        for id: InteractionID
    ) {
        tasks[id]?.cancel()
        tasks[id] = task
    }

    private func finish(_ id: InteractionID) {
        tasks[id] = nil
    }

    public func cancel(interactionID: InteractionID) async {
        let task = tasks.removeValue(forKey: interactionID)
        task?.cancel()
    }
}
