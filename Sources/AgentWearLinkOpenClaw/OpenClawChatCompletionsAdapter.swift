import Foundation
import AgentWearLinkCore

public actor OpenClawChatCompletionsAdapter: AgentAdapter {
    private struct TaskEntry {
        let generation: UUID
        let task: Task<Void, Never>
    }

    private let configuration: OpenClawConfiguration
    private let session: URLSession
    private var tasks: [InteractionID: TaskEntry] = [:]

    public init(
        configuration: OpenClawConfiguration,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.session = session
    }

    public func connect() async throws {}

    public func disconnect() async {
        let active = tasks.values.map(\.task)
        tasks.removeAll()
        active.forEach { $0.cancel() }
    }

    public func responses(
        for request: AgentRequest
    ) async -> AsyncThrowingStream<AgentResponse, Error> {
        let configuration = self.configuration
        let session = self.session
        let generation = UUID()
        let pair = AsyncThrowingStream<AgentResponse, Error>.makeStream()
        let continuation = pair.continuation

        let task = Task {
            var terminalError: Error?

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

                var sawDone = false

                streamLoop: for try await line in bytes.lines {
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
                        sawDone = true
                        continuation.yield(
                            .completed(request.interactionID)
                        )
                        break streamLoop

                    case .ignored:
                        break
                    }
                }

                try Task.checkCancellation()

                guard sawDone else {
                    throw AWLError.transport(
                        "OpenClaw SSE stream ended before [DONE]"
                    )
                }
            } catch is CancellationError {
                terminalError = AWLError.cancelled
            } catch let error as AgentRequestValidationError {
                terminalError = error
            } catch let error as AWLError {
                terminalError = error
            } catch {
                terminalError = AWLError.transport(error.localizedDescription)
            }

            await self.finish(
                request.interactionID,
                generation: generation
            )

            if let terminalError {
                continuation.finish(throwing: terminalError)
            } else {
                continuation.finish()
            }
        }

        if let previous = tasks[request.interactionID] {
            previous.task.cancel()
        }
        tasks[request.interactionID] = TaskEntry(
            generation: generation,
            task: task
        )

        continuation.onTermination = { [weak self] _ in
            task.cancel()
            Task {
                await self?.cancel(
                    interactionID: request.interactionID,
                    generation: generation
                )
            }
        }

        return pair.stream
    }

    private func finish(
        _ id: InteractionID,
        generation: UUID
    ) {
        guard tasks[id]?.generation == generation else { return }
        tasks[id] = nil
    }

    private func cancel(
        interactionID: InteractionID,
        generation: UUID
    ) {
        guard let entry = tasks[interactionID],
              entry.generation == generation else {
            return
        }
        tasks[interactionID] = nil
        entry.task.cancel()
    }

    public func cancel(interactionID: InteractionID) async {
        let entry = tasks.removeValue(forKey: interactionID)
        entry?.task.cancel()
    }

    func taskCount() -> Int {
        tasks.count
    }
}
