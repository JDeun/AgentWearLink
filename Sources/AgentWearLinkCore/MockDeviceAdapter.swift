import Foundation

/// Deterministic in-process device adapter for integration tests and demos.
///
/// This is an AWL mock, not Meta's Mock Device Kit. Meta's kit validates
/// vendor SDK behavior; this adapter validates AWL behavior without any SDK.
public actor MockDeviceAdapter: DeviceAdapter {
    public nonisolated let capabilities: CapabilitySet
    private nonisolated let eventSource = BoundedDeviceEventSource(bufferLimit: 64)

    public init(capabilities: CapabilitySet = [.textInput]) {
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
