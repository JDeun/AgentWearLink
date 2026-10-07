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

    private struct StartWaiter {
        let id: UUID
        let generation: UInt64
        let continuation: CheckedContinuation<Void, Error>
    }
    private var startWaiters: [StartWaiter] = []
    private var startupRetirementWaiters: [
        UInt64: [CheckedContinuation<Void, Never>]
    ] = [:]
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []

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
        while true {
            try Task.checkCancellation()

            switch lifecycleState {
            case .running:
                return

            case .starting:
                let generation = lifecycleGeneration
                try await waitForStart(generation: generation)
                return

            case .stopping:
                await waitForStop()
                continue

            case .stopped:
                break
            }
            break
        }

        lifecycleState = .starting
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration

        // stop() may need to wait for this exact startup attempt to retire before
        // admitting another generation.
        defer { retireStartup(generation: generation) }

        // Subscribe before connect so adapters that emit lifecycle events during
        // connection cannot race the runtime and lose their first event.
        let events = device.events()

        do {
            try Task.checkCancellation()
            try await agent.connect()
            try Task.checkCancellation()
            try requireActiveStartup(generation: generation)

            try await device.connect()
            try Task.checkCancellation()
            try requireActiveStartup(generation: generation)

            await coordinator.activate(runtimeGeneration: generation)
            try Task.checkCancellation()
            try requireActiveStartup(generation: generation)
        } catch {
            // A cancelled/superseded startup can finish a lower-level connect
            // after stop() has already changed the runtime generation. Always
            // roll both sides back before retiring this startup attempt.
            await coordinator.deactivate(runtimeGeneration: generation)
            await device.disconnect()
            await agent.disconnect()

            if lifecycleState == .starting,
               lifecycleGeneration == generation {
                lifecycleState = .stopped
            }

            finishStartWaiters(
                generation: generation,
                result: .failure(error)
            )
            throw error
        }

        lifecycleState = .running
        forwardingTask = Task { [coordinator] in
            for await event in events {
                guard !Task.isCancelled else { break }
                await coordinator.handle(event, runtimeGeneration: generation)
            }

            await self.forwardingDidEnd(
                generation: generation,
                wasCancelled: Task.isCancelled
            )
        }

        finishStartWaiters(generation: generation, result: .success(()))
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

        await coordinator.deactivate(runtimeGeneration: generation)
        await device.disconnect()
        await agent.disconnect()

        finishStopping()
        await output(
            .failed(
                nil,
                .device("device event stream ended unexpectedly")
            )
        )
    }

    public func stop() async {
        if lifecycleState == .stopping {
            await waitForStop()
            return
        }
        guard lifecycleState != .stopped else { return }

        let activeGeneration = lifecycleGeneration
        let wasStarting = lifecycleState == .starting

        lifecycleState = .stopping
        lifecycleGeneration &+= 1

        if wasStarting {
            finishStartWaiters(
                generation: activeGeneration,
                result: .failure(AgentWearLinkRuntimeError.startSuperseded)
            )

            // Do not let a late completion from the retired connect sequence
            // overlap a new runtime generation. The startup owner performs its
            // own rollback before this barrier opens.
            await waitForStartupRetirement(generation: activeGeneration)
        }

        forwardingTask?.cancel()
        forwardingTask = nil
        await coordinator.deactivate(runtimeGeneration: activeGeneration)
        await device.disconnect()
        await agent.disconnect()
        finishStopping()
    }

    /// Internal test probe used to replace scheduler-delay assumptions in
    /// lifecycle race regressions. This is intentionally not public API.
    func isStoppingForTesting() -> Bool {
        lifecycleState == .stopping
    }

    private func requireActiveStartup(generation: UInt64) throws {
        guard lifecycleState == .starting,
              lifecycleGeneration == generation else {
            throw AgentWearLinkRuntimeError.startSuperseded
        }
    }

    private func waitForStart(generation: UInt64) async throws {
        let id = UUID()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }

                startWaiters.append(
                    StartWaiter(
                        id: id,
                        generation: generation,
                        continuation: continuation
                    )
                )
            }
        } onCancel: {
            Task {
                await self.cancelStartWaiter(
                    id: id,
                    generation: generation
                )
            }
        }
    }

    private func cancelStartWaiter(id: UUID, generation: UInt64) {
        guard let index = startWaiters.firstIndex(where: {
            $0.id == id && $0.generation == generation
        }) else {
            return
        }

        let waiter = startWaiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func finishStartWaiters(
        generation: UInt64,
        result: Result<Void, Error>
    ) {
        var remaining: [StartWaiter] = []

        for waiter in startWaiters {
            guard waiter.generation == generation else {
                remaining.append(waiter)
                continue
            }

            switch result {
            case .success:
                waiter.continuation.resume()
            case let .failure(error):
                waiter.continuation.resume(throwing: error)
            }
        }

        startWaiters = remaining
    }

    private func waitForStartupRetirement(generation: UInt64) async {
        await withCheckedContinuation { continuation in
            startupRetirementWaiters[generation, default: []].append(
                continuation
            )
        }
    }

    private func retireStartup(generation: UInt64) {
        let waiters = startupRetirementWaiters.removeValue(
            forKey: generation
        ) ?? []
        for waiter in waiters { waiter.resume() }
    }

    private func waitForStop() async {
        await withCheckedContinuation { continuation in
            stopWaiters.append(continuation)
        }
    }

    private func finishStopping() {
        lifecycleState = .stopped
        let waiters = stopWaiters
        stopWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
    }
}

public enum AgentWearLinkRuntimeError: Error, Sendable, Equatable {
    case startSuperseded
}
