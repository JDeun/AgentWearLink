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

    /// Produces a finite-buffer device event stream.
    ///
    /// Implementations must install the producer-side subscription before
    /// `events()` returns and retain events emitted after that return even when
    /// the runtime has not started iterating yet. AgentWearLinkRuntime
    /// deliberately subscribes before `connect()` so connect-time lifecycle
    /// events cannot be lost. A zero-buffer/dropping-before-first-consumer
    /// stream therefore does not satisfy this contract.
    ///
    /// Implementations must not rely on the default unbounded `AsyncStream`
    /// buffering policy. Use a finite buffer (at least one retained event), or
    /// an equivalent coalescing strategy. If delivery cannot be kept lossless
    /// under that policy, surface overload explicitly rather than allowing
    /// memory growth or silent loss.
    func events() -> AsyncStream<InteractionEvent>
}

public enum AgentCancellationOutcome: Sendable, Equatable {
    /// The adapter completed its cancellation handling with no known
    /// uncertainty that needs to be surfaced by Core.
    case handled

    /// Local cleanup completed, but remote execution may still be active or
    /// the adapter could not prove that the remote abort took effect.
    case uncertain(AWLError)
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

    /// Performs cancellation and reports whether remote execution is known to
    /// be handled. Existing adapters remain source-compatible through the
    /// default implementation below.
    func cancellationOutcome(
        interactionID: InteractionID
    ) async -> AgentCancellationOutcome
}

public extension AgentAdapter {
    func cancellationOutcome(
        interactionID: InteractionID
    ) async -> AgentCancellationOutcome {
        await cancel(interactionID: interactionID)
        return .handled
    }
}
