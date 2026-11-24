import Foundation

/// Retry schedule for the glasses-mic experiment's recognition task after a
/// real recognizer error (missing on-device model, 1101/1110 …): 0.5 s
/// doubling to 10 s, so a persistent error never spins. A cancellation of a
/// task the adapter cancelled itself is not an error (it is ignored by
/// generation), and any recognised text resets the count.
public enum GlassesMicRetry {
    public static let first: TimeInterval = 0.5
    public static let maximum: TimeInterval = 10

    public static func delay(afterErrors errors: Int) -> TimeInterval {
        guard errors > 0 else { return 0 }
        return min(first * pow(2, Double(min(errors - 1, 16))), maximum)
    }

    /// Only callbacks from the current recognition task count; a cancelled
    /// or replaced task still calls back (with partials or a cancellation
    /// error) and must change nothing.
    public static func isCurrent(callbackGeneration: UInt64, current: UInt64, running: Bool) -> Bool {
        running && callbackGeneration == current
    }

    /// "No speech detected" (kAFAssistantErrorDomain 1110) ends a task that
    /// heard only silence: restart at once, unless the task died right
    /// away (then it is treated as a real error and backs off).
    public static func isQuietEnd(domain: String?, code: Int?, taskAge: TimeInterval) -> Bool {
        domain == "kAFAssistantErrorDomain" && code == 1110 && taskAge >= 1
    }

    /// Minimum spacing between engine restart attempts by the watchdog.
    public static let engineRestartSpacing: TimeInterval = 2
}

/// A single, non-renewing foreground experiment grant. Explicit UI action
/// creates it; callbacks and automatic recovery cannot extend the hard cap.
public struct HFPListeningLease: Sendable, Equatable {
    public enum End: String, Sendable, Equatable {
        case expired, inactive, stopped, background, interrupted, routeLost,
             competingAudio, powerRestricted, recognitionFailed, engineFailed,
             connectionFailed, deliveryFailed
    }

    public static let allowedSeconds = [60, 120, 300]
    public static let defaultSeconds = 120
    public static let idleSeconds = 30
    public static let maximumRecognizerErrors = 3
    public static let maximumEngineRestarts = 2

    public let id: UUID
    public let began: ContinuousClock.Instant
    public let deadline: ContinuousClock.Instant
    public private(set) var lastActivity: ContinuousClock.Instant

    public init?(seconds: Int, now: ContinuousClock.Instant = .now, id: UUID = UUID()) {
        guard Self.allowedSeconds.contains(seconds) else { return nil }
        self.id = id
        began = now
        deadline = now.advanced(by: .seconds(seconds))
        lastActivity = now
    }

    public func isWithinHardLimit(at now: ContinuousClock.Instant = .now) -> Bool {
        now >= began && now < deadline
    }

    /// An actual nonempty recognition result can refresh inactivity only.
    /// Repeated empty callbacks and automatic recognition restarts cannot.
    public mutating func noteActivity(at now: ContinuousClock.Instant) {
        guard isWithinHardLimit(at: now), now >= lastActivity else { return }
        lastActivity = now
    }

    public func end(at now: ContinuousClock.Instant, routeAvailable: Bool, competingAudio: Bool) -> End? {
        guard isWithinHardLimit(at: now) else { return .expired }
        guard routeAvailable else { return .routeLost }
        guard !competingAudio else { return .competingAudio }
        if now - lastActivity >= .seconds(Self.idleSeconds) { return .inactive }
        return nil
    }
}
