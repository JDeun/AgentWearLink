import Foundation

public protocol AgentTransport: Sendable {
    func connect() async throws
    func disconnect() async
    func send(_ request: AgentRequest) async -> AsyncThrowingStream<AgentResponse, Error>
    func cancel(interactionID: InteractionID) async
}

/// Adapts a transport into the public AgentAdapter boundary.
///
/// Runtime-specific adapters may wrap a transport and transform protocol
/// payloads without changing the coordinator.
public actor TransportAgentAdapter: AgentAdapter {
    private let transport: any AgentTransport

    public init(transport: any AgentTransport) {
        self.transport = transport
    }

    public func connect() async throws {
        try await transport.connect()
    }

    public func disconnect() async {
        await transport.disconnect()
    }

    public func responses(
        for request: AgentRequest
    ) async -> AsyncThrowingStream<AgentResponse, Error> {
        await transport.send(request)
    }

    public func cancel(interactionID: InteractionID) async {
        await transport.cancel(interactionID: interactionID)
    }
}
