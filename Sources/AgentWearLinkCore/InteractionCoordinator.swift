import Foundation

private actor InteractionOutputQueue {
    private let output: @Sendable (InteractionEvent) async -> Void
    private var tail: Task<Void, Never>?
    private var generation: UInt64 = 0

    init(output: @escaping @Sendable (InteractionEvent) async -> Void) {
        self.output = output
    }

    func emit(_ event: InteractionEvent) async {
        generation &+= 1
        let emissionGeneration = generation
        let previous = tail
        let output = self.output

        let task = Task {
            if let previous {
                await previous.value
            }
            await output(event)
        }

        tail = task
        await task.value

        if generation == emissionGeneration {
            tail = nil
        }
    }
}

public actor InteractionCoordinator {
    public static let defaultMaximumInFlightInteractions = 8
    public static let defaultMaximumRequestTextBytes = AgentRequest.defaultMaximumTextBytes
    private static let maximumDeviceTerminalHistory = 64

    private struct TaskEntry {
        let generation: UUID
        let task: Task<Void, Never>
    }

    private let agent: any AgentAdapter
    private let maximumInFlightInteractions: Int
    private let maximumRequestTextBytes: Int
    private var tasks: [InteractionID: TaskEntry] = [:]
    private let outputQueue: InteractionOutputQueue
    private var activeRuntimeGeneration: UInt64?
    private var terminalDeviceInteractions: Set<InteractionID> = []
    private var terminalDeviceOrder: [InteractionID] = []

    public init(
        agent: any AgentAdapter,
        maximumInFlightInteractions: Int = InteractionCoordinator.defaultMaximumInFlightInteractions,
        maximumRequestTextBytes: Int = InteractionCoordinator.defaultMaximumRequestTextBytes,
        output: @escaping @Sendable (InteractionEvent) async -> Void
    ) {
        precondition(maximumInFlightInteractions > 0)
        precondition(maximumRequestTextBytes > 0)
        self.agent = agent
        self.maximumInFlightInteractions = maximumInFlightInteractions
        self.maximumRequestTextBytes = maximumRequestTextBytes
        self.outputQueue = InteractionOutputQueue(output: output)
    }

    public func activate(runtimeGeneration: UInt64) {
        activeRuntimeGeneration = runtimeGeneration
    }

    public func deactivate(runtimeGeneration: UInt64) async {
        guard activeRuntimeGeneration == runtimeGeneration else { return }
        activeRuntimeGeneration = nil
        await cancelAll()
    }

    public func handle(_ event: InteractionEvent, runtimeGeneration: UInt64) async {
        guard activeRuntimeGeneration == runtimeGeneration else { return }
        await handle(event)
    }

    public func handle(_ event: InteractionEvent) async {
        guard let id = event.interactionID else {
            if event.isTerminalGlobalDeviceFailure {
                await cancelAll()
            }
            await outputQueue.emit(event)
            return
        }

        switch event {
        case .interrupted, .sessionEnded:
            guard rememberDeviceTerminal(id) else { return }
            await cancel(id)
            await outputQueue.emit(event)
        case .failed:
            guard rememberDeviceTerminal(id) else { return }
            await cancel(id)
            await outputQueue.emit(event)
        case .sessionStarted:
            resetDeviceTerminal(id)
            await outputQueue.emit(event)
        case .turnCompleted:
            await outputQueue.emit(event)
        case let .text(_, text):
            await submit(.init(interactionID: id, text: text))
        case let .invocation(_, phrase):
            guard let phrase, !phrase.isEmpty else {
                await outputQueue.emit(event)
                return
            }
            await submit(.init(interactionID: id, text: phrase))
        }
    }

    private func submit(_ request: AgentRequest) async {
        let id = request.interactionID
        guard tasks[id] == nil else { return }

        guard request.textUTF8ByteCount <= maximumRequestTextBytes else {
            await outputQueue.emit(
                .failed(
                    id,
                    .overloaded("agent request text exceeds configured byte limit")
                )
            )
            return
        }

        guard tasks.count < maximumInFlightInteractions else {
            await outputQueue.emit(
                .failed(
                    id,
                    .overloaded("maximum in-flight interaction capacity reached")
                )
            )
            return
        }

        let generation = UUID()
        let task = Task { [agent] in
            do {
                let responses = await agent.responses(for: request)
                var observedTerminal = false

                responseLoop: for try await response in responses {
                    guard !Task.isCancelled else { break responseLoop }
                    guard response.interactionID == id else {
                        observedTerminal = true
                        let cancellationOutcome = await agent.cancellationOutcome(
                            interactionID: id
                        )
                        await self.emitCancellationDiagnosticIfNeeded(
                            cancellationOutcome
                        )
                        _ = await self.emitIfCurrent(
                            .failed(id, .agent("response interaction ID mismatch")),
                            id: id,
                            generation: generation
                        )
                        break responseLoop
                    }

                    switch response {
                    case let .textDelta(responseID, text):
                        guard await self.emitIfCurrent(
                            .text(responseID, text),
                            id: id,
                            generation: generation
                        ) else {
                            break responseLoop
                        }

                    case let .completed(responseID):
                        observedTerminal = true
                        _ = await self.emitIfCurrent(
                            .turnCompleted(responseID),
                            id: id,
                            generation: generation
                        )
                        break responseLoop

                    case let .failed(responseID, error):
                        observedTerminal = true
                        _ = await self.emitIfCurrent(
                            .failed(responseID, error),
                            id: id,
                            generation: generation
                        )
                        break responseLoop
                    }
                }

                if !observedTerminal && !Task.isCancelled {
                    _ = await self.emitIfCurrent(
                        .failed(
                            id,
                            .agent("response stream ended without terminal response")
                        ),
                        id: id,
                        generation: generation
                    )
                }
            } catch is CancellationError {
                // Lifecycle cancellation already carries the semantic event.
            } catch let error as AWLError {
                _ = await self.emitIfCurrent(
                    .failed(id, error),
                    id: id,
                    generation: generation
                )
            } catch {
                _ = await self.emitIfCurrent(
                    .failed(id, .agent(String(describing: error))),
                    id: id,
                    generation: generation
                )
            }

            await self.finish(id, generation: generation)
        }

        tasks[id] = TaskEntry(generation: generation, task: task)
    }

    private func emitIfCurrent(
        _ event: InteractionEvent,
        id: InteractionID,
        generation: UUID
    ) async -> Bool {
        guard tasks[id]?.generation == generation else { return false }

        // Enqueue while this generation still owns the interaction. The output
        // queue serializes committed emissions, so a later interruption/session
        // end cannot become externally visible before an already-committed
        // response and then be followed by stale text from the retired task.
        await outputQueue.emit(event)

        return tasks[id]?.generation == generation
    }

    private func rememberDeviceTerminal(_ id: InteractionID) -> Bool {
        guard terminalDeviceInteractions.insert(id).inserted else {
            return false
        }

        terminalDeviceOrder.append(id)
        if terminalDeviceOrder.count > Self.maximumDeviceTerminalHistory {
            let expired = terminalDeviceOrder.removeFirst()
            terminalDeviceInteractions.remove(expired)
        }
        return true
    }

    private func resetDeviceTerminal(_ id: InteractionID) {
        terminalDeviceInteractions.remove(id)
        terminalDeviceOrder.removeAll { $0 == id }
    }

    func inFlightInteractionCount() -> Int { tasks.count }

    private func finish(_ id: InteractionID, generation: UUID) {
        guard tasks[id]?.generation == generation else { return }
        tasks[id] = nil
    }

    public func cancel(_ id: InteractionID) async {
        guard let entry = tasks.removeValue(forKey: id) else { return }
        entry.task.cancel()
        let outcome = await agent.cancellationOutcome(interactionID: id)
        await emitCancellationDiagnosticIfNeeded(outcome)
    }

    private func emitCancellationDiagnosticIfNeeded(
        _ outcome: AgentCancellationOutcome
    ) async {
        guard case let .uncertain(error) = outcome else { return }

        // Nil-ID non-device failures are diagnostics, not runtime-terminal
        // device/session failures. This preserves the local lifecycle event
        // while making uncertain remote execution observable.
        await outputQueue.emit(.failed(nil, error))
    }

    public func cancelAll() async {
        let ids = Array(tasks.keys)
        for id in ids {
            await cancel(id)
        }
    }
}
