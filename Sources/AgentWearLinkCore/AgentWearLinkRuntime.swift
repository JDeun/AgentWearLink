import Foundation

/// Connects one device event stream to one agent-facing coordinator.
///
/// The runtime owns forwarding tasks and provides deterministic shutdown.
public actor AgentWearLinkRuntime {
    private let device: any DeviceAdapter
    private let agent: any AgentAdapter
    private let coordinator: InteractionCoordinator
    private let output: @Sendable (InteractionEvent) async -> Void
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
        self.output = output
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
                await device.disconnect()
                await agent.disconnect()
                return
            }

            try await device.connect()
            guard lifecycleState == .starting, lifecycleGeneration == generation else {
                await device.disconnect()
                await agent.disconnect()
                return
            }
        } catch {
            // `events()` has already installed the device-side subscription and
            // either adapter may have acquired resources before throwing. Treat
            // startup as one transaction and roll both sides back.
            await device.disconnect()
            await agent.disconnect()
            if lifecycleGeneration == generation {
                lifecycleState = .stopped
            }
            throw error
        }

        lifecycleState = .running
        forwardingTask = Task { [coordinator] in
            for await event in events {
                guard !Task.isCancelled else { break }
                await coordinator.handle(event)
            }

            await self.forwardingDidEnd(
                generation: generation,
                wasCancelled: Task.isCancelled
            )
        }
    }

    private func forwardingDidEnd(
        generation: UInt64,
        wasCancelled: Bool
    ) async {
        guard !wasCancelled,
              lifecycleState == .running,
              lifecycleGeneration == generation else {
            return
        }

        // Own the teardown here rather than recursively calling stop(). The
        // forwarding task is the caller, so cancelling/awaiting it from stop()
        // would couple cleanup to the task that is reporting the failure.
        lifecycleState = .stopping
        lifecycleGeneration &+= 1
        forwardingTask = nil

        await coordinator.cancelAll()
        await device.disconnect()
        await agent.disconnect()

        lifecycleState = .stopped
        await output(
            .failed(
                nil,
                .device("device event stream ended unexpectedly")
            )
        )
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
