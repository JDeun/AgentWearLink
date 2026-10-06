import Foundation

/// Connects one device event stream to one agent-facing coordinator.
///
/// The runtime owns forwarding tasks and provides deterministic shutdown.
public actor AgentWearLinkRuntime {
    private let device: any DeviceAdapter
    private let agent: any AgentAdapter
    private let coordinator: InteractionCoordinator
    private var forwardingTask: Task<Void, Never>?

    public init(
        device: any DeviceAdapter,
        agent: any AgentAdapter,
        output: @escaping @Sendable (InteractionEvent) async -> Void
    ) {
        self.device = device
        self.agent = agent
        self.coordinator = InteractionCoordinator(agent: agent, output: output)
    }

    public func start() async throws {
        guard forwardingTask == nil else { return }

        // Subscribe before connect so adapters that emit lifecycle events during
        // connection cannot race the runtime and lose their first event.
        let events = device.events()

        try await agent.connect()
        do {
            try await device.connect()
        } catch {
            await agent.disconnect()
            throw error
        }

        forwardingTask = Task { [coordinator] in
            for await event in events {
                guard !Task.isCancelled else { break }
                await coordinator.handle(event)
            }
        }
    }

    public func stop() async {
        forwardingTask?.cancel()
        forwardingTask = nil
        await coordinator.cancelAll()
        await device.disconnect()
        await agent.disconnect()
    }
}
