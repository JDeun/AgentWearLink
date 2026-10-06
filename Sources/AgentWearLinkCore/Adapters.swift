public protocol DeviceAdapter: Sendable {
    var capabilities: CapabilitySet { get }

    func connect() async throws
    func disconnect() async
    func events() -> AsyncStream<InteractionEvent>
}

public protocol AgentAdapter: Sendable {
    func connect() async throws
    func disconnect() async
    func responses(for request: AgentRequest) async -> AsyncThrowingStream<AgentResponse, Error>
    func cancel(interactionID: InteractionID) async
}
