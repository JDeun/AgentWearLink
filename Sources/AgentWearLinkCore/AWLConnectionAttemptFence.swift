/// Prevents overlapping host connection attempts and fences asynchronous
/// completions after a user-initiated disconnect. Pure state, no transport.
public struct AWLConnectionAttemptFence: Sendable {
    public private(set) var generation: UInt64 = 0
    private var startingAttempt: UInt64?

    public init() {}

    public var isStarting: Bool { startingAttempt != nil }

    /// Returns nil while a previous start still owns cleanup.
    public mutating func begin() -> UInt64? {
        guard startingAttempt == nil else { return nil }
        generation &+= 1
        startingAttempt = generation
        return generation
    }

    /// Disconnect invalidates all suspended startup continuations before
    /// awaiting transport teardown, while retaining exclusive cleanup.
    public mutating func invalidate() {
        generation &+= 1
    }

    public func isCurrent(_ attempt: UInt64) -> Bool {
        startingAttempt == attempt && generation == attempt
    }

    /// For callbacks from a running connection *after* finish() has cleared
    /// the startup marker. Invalidated by explicit disconnect or a new begin.
    public func ownsRuntime(_ attempt: UInt64) -> Bool {
        generation == attempt
    }

    public mutating func finish(_ attempt: UInt64) {
        guard startingAttempt == attempt else { return }
        startingAttempt = nil
    }
}
