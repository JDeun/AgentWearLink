import Foundation

private final class MockDeviceEventSource: @unchecked Sendable {
    private struct Subscription {
        let id: UUID
        let continuation: AsyncStream<InteractionEvent>.Continuation
    }

    private let lock = NSLock()
    private var subscription: Subscription?

    func stream() -> AsyncStream<InteractionEvent> {
        let id = UUID()

        return AsyncStream { continuation in
            continuation.onTermination = { [weak self] _ in
                self?.remove(id: id)
            }

            let previous = lock.withLock { () -> AsyncStream<InteractionEvent>.Continuation? in
                let previous = subscription?.continuation
                subscription = Subscription(id: id, continuation: continuation)
                return previous
            }

            previous?.finish()
        }
    }

    func yield(_ event: InteractionEvent) {
        let continuation = lock.withLock { subscription?.continuation }
        continuation?.yield(event)
    }

    func finish() {
        let continuation = lock.withLock { () -> AsyncStream<InteractionEvent>.Continuation? in
            let continuation = subscription?.continuation
            subscription = nil
            return continuation
        }

        continuation?.finish()
    }

    private func remove(id: UUID) {
        lock.withLock {
            guard subscription?.id == id else { return }
            subscription = nil
        }
    }
}

/// Deterministic in-process device adapter for integration tests and demos.
///
/// This is an AWL mock, not Meta's Mock Device Kit. Meta's kit validates
/// vendor SDK behavior; this adapter validates AWL behavior without any SDK.
public actor MockDeviceAdapter: DeviceAdapter {
    public nonisolated let capabilities: CapabilitySet
    private nonisolated let eventSource = MockDeviceEventSource()

    public init(capabilities: CapabilitySet = [.textInput, .textOutput]) {
        self.capabilities = capabilities
    }

    public func connect() async throws {}

    public func disconnect() async {
        eventSource.finish()
    }

    public nonisolated func events() -> AsyncStream<InteractionEvent> {
        eventSource.stream()
    }

    public func emit(_ event: InteractionEvent) {
        eventSource.yield(event)
    }
}
