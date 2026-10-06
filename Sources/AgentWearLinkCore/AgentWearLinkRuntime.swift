import Foundation

/// Connects one device event stream to one agent-facing coordinator.
///
/// The runtime owns forwarding tasks and provides deterministic shutdown.
public actor AgentWearLinkRuntime {
    private let device: any DeviceAdapter
    private let agent: any AgentAdapter
    private let coordinator: InteractionCoordinator
    private var forwardingTask: Task<Void, Never>?
    private enum LifecycleState { case stopped, starting, running, stopping }
    private var lifecycleState: LifecycleState = .stopped
    private var lifecycleGeneration: UInt64 = 0

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
        guard lifecycleState == .stopped else { return }
        lifecycleState = .starting
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration

        // Subscribe before connect so adapters that emit lifecycle events during
        // connection cannot race the runtime and lose their first event.
        let events = device.events()

        do {
            try await agent.connect()
            guard lifecycleState == .starting, lifecycleGeneration == generation else {
                await agent.disconnect()
                return
            }
            do {
                try await device.connect()
                guard lifecycleState == .starting, lifecycleGeneration == generation else {
                    await device.disconnect()
                    await agent.disconnect()
                    return
                }
            } catch {
                await device.disconnect()
                await agent.disconnect()
                if lifecycleGeneration == generation { lifecycleState = .stopped }
                throw error
            }
        } catch {
            if lifecycleGeneration == generation { lifecycleState = .stopped }
            throw error
        }

        forwardingTask = Task { [coordinator] in
            for await event in events {
                guard !Task.isCancelled else { break }
                await coordinator.handle(event)
            }
        }
        lifecycleState = .running
    }

    public func stop() async {
        guard lifecycleState != .stopped, lifecycleState != .stopping else { return }
        lifecycleState = .stopping
        lifecycleGeneration &+= 1
        forwardingTask?.cancel()
        forwardingTask = nil
        await coordinator.cancelAll()
        await device.disconnect()
        await agent.disconnect()
        lifecycleState = .stopped
    }
}
