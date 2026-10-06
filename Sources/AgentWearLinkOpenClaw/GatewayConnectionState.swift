public enum GatewayConnectionState: Sendable, Equatable {
    case disconnected
    case connecting
    case authenticating
    case ready
    case reconnecting(attempt: Int)
    case failed(String)

    public var canSendRequests: Bool {
        self == .ready
    }
}

/// Reconnect policy for mobile/Tailnet network transitions.
///
/// Reconnect restores the transport session only. It never authorizes silent
/// replay of an application request whose delivery is uncertain.
public struct GatewayReconnectPolicy: Sendable, Equatable {
    public let initialDelayMilliseconds: Int
    public let maximumDelayMilliseconds: Int
    public let maximumAttempts: Int?

    public init(
        initialDelayMilliseconds: Int = 1_000,
        maximumDelayMilliseconds: Int = 30_000,
        maximumAttempts: Int? = nil
    ) {
        precondition(initialDelayMilliseconds > 0)
        precondition(maximumDelayMilliseconds >= initialDelayMilliseconds)
        self.initialDelayMilliseconds = initialDelayMilliseconds
        self.maximumDelayMilliseconds = maximumDelayMilliseconds
        self.maximumAttempts = maximumAttempts
    }

    public func delayMilliseconds(forAttempt attempt: Int) -> Int {
        guard attempt > 1 else { return initialDelayMilliseconds }

        var delay = initialDelayMilliseconds
        for _ in 1..<attempt {
            if delay >= maximumDelayMilliseconds / 2 {
                return maximumDelayMilliseconds
            }
            delay *= 2
        }
        return min(delay, maximumDelayMilliseconds)
    }
}
