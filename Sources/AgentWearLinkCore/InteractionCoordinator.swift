import Foundation

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

        let task = Task { [agent, output] in
            do {
                for try await response in agent.responses(for: request) {
                    guard !Task.isCancelled else { break }
                    switch response {
                    case let .textDelta(responseID, text):
                        await output(.text(responseID, text))
                    case let .completed(responseID):
                        await output(.sessionEnded(responseID))
                    case let .failed(responseID, error):
                        await output(.failed(responseID, error))
                    }
                }
            } catch is CancellationError {
                // Lifecycle cancellation already carries the semantic event.
            } catch {
                await output(.failed(id, .agent(String(describing: error))))
            }
        }

        tasks[id] = task
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
