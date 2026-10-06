import Foundation

public actor InteractionCoordinator {
    private struct TaskEntry {
        let generation: UUID
        let task: Task<Void, Never>
    }

    public static let defaultMaximumInFlightInteractions = 8

    private let agent: any AgentAdapter
    private let maximumInFlightInteractions: Int
    private var tasks: [InteractionID: TaskEntry] = [:]
    private let output: @Sendable (InteractionEvent) async -> Void

    public init(
        agent: any AgentAdapter,
        maximumInFlightInteractions: Int = 8,
        output: @escaping @Sendable (InteractionEvent) async -> Void
    ) {
        precondition(maximumInFlightInteractions > 0)
        self.agent = agent
        self.maximumInFlightInteractions = maximumInFlightInteractions
        self.output = output
    }

    public func handle(_ event: InteractionEvent) async {
        guard let id = event.interactionID else {
            await output(event)
            return
        }

        switch event {
        case .interrupted, .sessionEnded:
            await cancel(id)
            await output(event)
        case .failed:
            await cancel(id)
            await output(event)
        case .sessionStarted:
            await output(event)
        case let .text(_, text):
            await submit(.init(interactionID: id, text: text))
        case let .invocation(_, phrase):
            guard let phrase, !phrase.isEmpty else {
                await output(event)
                return
            }
            await submit(.init(interactionID: id, text: phrase))
        }
    }

    private func submit(_ request: AgentRequest) async {
        let id = request.interactionID
        guard tasks[id] == nil else { return }

        guard tasks.count < maximumInFlightInteractions else {
            await output(
                .failed(
                    id,
                    .overloaded("maximum in-flight interaction capacity reached")
                )
            )
            return
        }

        let generation = UUID()
        let task = Task { [agent, output] in
            do {
                let responses = await agent.responses(for: request)
                var observedTerminal = false

                responseLoop: for try await response in responses {
                    guard !Task.isCancelled else { break responseLoop }
                    guard response.interactionID == id else {
                        observedTerminal = true
                        await agent.cancel(interactionID: id)
                        await output(.failed(id, .agent("response interaction ID mismatch")))
                        break responseLoop
                    }

                    switch response {
                    case let .textDelta(responseID, text):
                        await output(.text(responseID, text))

                    case let .completed(responseID):
                        observedTerminal = true
                        await output(.sessionEnded(responseID))
                        break responseLoop

                    case let .failed(responseID, error):
                        observedTerminal = true
                        await output(.failed(responseID, error))
                        break responseLoop
                    }
                }

                if !observedTerminal && !Task.isCancelled {
                    await output(
                        .failed(
                            id,
                            .agent("response stream ended without terminal response")
                        )
                    )
                }
            } catch is CancellationError {
                // Lifecycle cancellation already carries the semantic event.
            } catch let error as AWLError {
                await output(.failed(id, error))
            } catch {
                await output(.failed(id, .agent(String(describing: error))))
            }

            await self.finish(id, generation: generation)
        }

        tasks[id] = TaskEntry(generation: generation, task: task)
    }

    func inFlightInteractionCount() -> Int {
        tasks.count
    }

    private func finish(_ id: InteractionID, generation: UUID) {
        guard tasks[id]?.generation == generation else { return }
        tasks[id] = nil
    }

    public func cancel(_ id: InteractionID) async {
        guard let entry = tasks.removeValue(forKey: id) else { return }
        entry.task.cancel()
        await agent.cancel(interactionID: id)
    }

    public func cancelAll() async {
        let ids = Array(tasks.keys)
        for id in ids {
            await cancel(id)
        }
    }
}
