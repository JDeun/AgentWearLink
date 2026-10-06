public protocol DeviceAdapter: Sendable {
    var capabilities: CapabilitySet { get }

    func connect() async throws
    func disconnect() async
    func events() -> AsyncStream<InteractionEvent>
}

public protocol AgentAdapter: Sendable {
    func connect() async throws
    func disconnect() async
    func responses(for event: InteractionEvent) -> AsyncThrowingStream<InteractionEvent, Error>
    func cancel(interactionID: InteractionID) async
}
