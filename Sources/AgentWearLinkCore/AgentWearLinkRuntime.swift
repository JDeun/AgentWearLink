import Foundation

/// Connects one device event stream to one agent-facing coordinator.
///
/// The runtime owns forwarding tasks and provides deterministic shutdown.
public actor AgentWearLinkRuntime {
    private let device: any DeviceAdapter
    private let agent: any AgentAdapter
    private let coordinator: InteractionCoordinator
    private var forwardingTask: Task<Void, Never>?
    private enum LifecycleState {
        case stopped
        case starting
        case running
        case stopping
    }
    private var lifecycleState: LifecycleState = .stopped

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

        // Subscribe before connect so adapters that emit lifecycle events during
        // connection cannot race the runtime and lose their first event.
        let events = device.events()

        do {
            try await agent.connect()
            do {
                try await device.connect()
            } catch {
                // A device connect implementation may have acquired partial
                // resources before throwing. DeviceAdapter.disconnect() is the
                // rollback boundary and must be safe to call after failed connect.
                await device.disconnect()
                await agent.disconnect()
                lifecycleState = .stopped
                throw error
            }
        } catch {
            lifecycleState = .stopped
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

        forwardingTask?.cancel()
        forwardingTask = nil
        await coordinator.cancelAll()
        await device.disconnect()
        await agent.disconnect()
        lifecycleState = .stopped
    }
}
