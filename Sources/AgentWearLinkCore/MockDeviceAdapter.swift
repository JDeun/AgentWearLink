import Foundation

/// Deterministic in-process device adapter for integration tests and demos.
///
/// This is an AWL mock, not Meta's Mock Device Kit. Meta's kit validates
/// vendor SDK behavior; this adapter validates AWL behavior without any SDK.
public actor MockDeviceAdapter: DeviceAdapter {
    public nonisolated let capabilities: CapabilitySet
    private var continuation: AsyncStream<InteractionEvent>.Continuation?

    public init(capabilities: CapabilitySet = [.textInput, .textOutput]) {
        self.capabilities = capabilities
    }

    public func connect() async throws {}

    public func disconnect() async {
        continuation?.finish()
        continuation = nil
    }

    public nonisolated func events() -> AsyncStream<InteractionEvent> {
        AsyncStream { continuation in
            Task { await self.install(continuation) }
        }
    }

    private func install(_ continuation: AsyncStream<InteractionEvent>.Continuation) {
        self.continuation?.finish()
        self.continuation = continuation
    }

    public func emit(_ event: InteractionEvent) {
        continuation?.yield(event)
    }
}
