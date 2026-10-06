import Foundation

/// Coordinates one normalized device event with one agent response stream.
///
/// The coordinator deliberately contains no device-vendor or agent-runtime
/// knowledge. It enforces only cross-adapter interaction invariants.
public actor InteractionCoordinator {
    private let agent: any AgentAdapter
    private var tasks: [InteractionID: Task<Void, Never>] = [:]
    private let output: @Sendable (InteractionEvent) async -> Void

    public init(
        agent: any AgentAdapter,
        output: @escaping @Sendable (InteractionEvent) async -> Void
    ) {
        self.agent = agent
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

        case .text, .invocation:
            // A duplicate request for the same interaction must never create
            // two concurrent agent streams.
            guard tasks[id] == nil else { return }

            let task = Task { [agent, output] in
                do {
                    for try await response in agent.responses(for: event) {
                        guard !Task.isCancelled else { break }
                        await output(response)
                    }
                } catch is CancellationError {
                    // Cancellation is represented by the lifecycle event that
                    // initiated it; do not emit a duplicate failure.
                } catch {
                    await output(.failed(id, .agent(String(describing: error))))
                }
            }

            tasks[id] = task
        }
    }

    public func cancel(_ id: InteractionID) async {
        tasks[id]?.cancel()
        tasks[id] = nil
        await agent.cancel(interactionID: id)
    }

    public func cancelAll() async {
        let ids = Array(tasks.keys)
        for id in ids {
            await cancel(id)
        }
    }
}
