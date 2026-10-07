public protocol DeviceAdapter: Sendable {
    var capabilities: CapabilitySet { get }

    /// Establishes the device-side connection.
    ///
    /// Implementations may acquire resources before throwing. Callers are
    /// therefore allowed to invoke `disconnect()` after a failed `connect()`.
    func connect() async throws

    /// Releases all resources owned by the adapter.
    ///
    /// This must be safe and idempotent after a successful connection, a
    /// partially failed connection, or when no connection was established.
    func disconnect() async

    func events() -> AsyncStream<InteractionEvent>
}

public protocol AgentAdapter: Sendable {
    /// Establishes the agent-side connection.
    ///
    /// Implementations may acquire resources before throwing. Callers are
    /// therefore allowed to invoke `disconnect()` after a failed `connect()`.
    func connect() async throws

    /// Releases all resources owned by the adapter.
    ///
    /// This must be safe and idempotent after a successful connection, a
    /// partially failed connection, or when no connection was established.
    func disconnect() async

    /// Produces a finite-buffer response stream.
    ///
    /// Implementations must not use the default unbounded AsyncThrowingStream
    /// policy. If a slow consumer exhausts the configured response buffer,
    /// terminate with AWLError.overloaded rather than silently dropping data or
    /// later presenting a successful terminal response after data loss.
    func responses(for request: AgentRequest) async -> AsyncThrowingStream<AgentResponse, Error>
    func cancel(interactionID: InteractionID) async
}
