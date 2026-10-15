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
