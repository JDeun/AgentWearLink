import Foundation

/// SDK-reported state is not proof that the glasses actually hear the wearer.
/// The 1.1.0 Speech interface exposes no recognition-completion reason or
/// guaranteed heartbeat interval. Keep callback evidence separate.
public struct MetaDATSpeechHealth: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case detached, starting, started, stopping, stopped
    }

    public enum CallbackEvidence: Sendable, Equatable {
        case unavailable
        case notObserved
        case stale
        case recentCallbackOnly
        case recentNonEmptyCallback
    }

    public let sessionStarted: Bool
    public let phase: Phase
    public let deliveryActive: Bool
    public let lastCallbackAt: ContinuousClock.Instant?
    public let lastNonEmptyCallbackAt: ContinuousClock.Instant?

    public init(
        sessionStarted: Bool,
        phase: Phase,
        deliveryActive: Bool,
        lastCallbackAt: ContinuousClock.Instant? = nil,
        lastNonEmptyCallbackAt: ContinuousClock.Instant? = nil
    ) {
        self.sessionStarted = sessionStarted
        self.phase = phase
        self.deliveryActive = deliveryActive
        self.lastCallbackAt = lastCallbackAt
        self.lastNonEmptyCallbackAt = lastNonEmptyCallbackAt
    }

    /// The SDK says the current attachment can receive input. This is not
    /// a guarantee of recognition, low-power wake, or microphone routing.
    public var isSDKReady: Bool {
        sessionStarted && phase == .started && deliveryActive
    }

    /// A caller chooses its own diagnostic window; no vendor heartbeat
    /// interval is assumed. Absence of recent callbacks is not a fault by
    /// itself (the wearer may be silent). Never trigger a restart here.
    public func callbackEvidence(
        now: ContinuousClock.Instant = .now,
        freshness: Duration
    ) -> CallbackEvidence {
        guard isSDKReady else { return .unavailable }
        precondition(freshness > .zero)
        guard let lastCallbackAt else { return .notObserved }
        guard lastCallbackAt <= now, now - lastCallbackAt <= freshness else {
            return .stale
        }
        if let lastNonEmptyCallbackAt,
           lastNonEmptyCallbackAt <= now,
           now - lastNonEmptyCallbackAt <= freshness {
            return .recentNonEmptyCallback
        }
        return .recentCallbackOnly
    }
}
