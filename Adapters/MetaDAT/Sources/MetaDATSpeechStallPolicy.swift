import Foundation

/// Field evidence (iOS DAT 1.0.0 on real Ray-Ban Meta): Speech can stay
/// "started" on a connected session while it stops delivering transcripts,
/// or keeps delivering only empty ones without hearing anything. While it
/// listens it emits a transcription event roughly every 0.3 s even in
/// silence, so a long gap means a stall. A Speech stop/start (not a session
/// teardown) fixes both.
public enum MetaDATSpeechStallPolicy {
    /// No transcription event of any kind for this long: stalled.
    public static let noEventLimit: TimeInterval = 4
    /// Only empty transcripts for this long: deaf. Silence also yields only
    /// empty transcripts, so this must be long: at 20 s a quiet room
    /// restarted Speech every 20 s (2026-10-14 field log), cutting off the
    /// start of the next utterance and costing battery. The no-event rule
    /// above still catches a real stall within seconds.
    public static let emptyOnlyLimit: TimeInterval = 180
    /// Pause between stop() and start() of a stall restart.
    public static let restartGap: Duration = .milliseconds(600)
    /// How often the adapter checks.
    public static let checkInterval: Duration = .seconds(2)

    public enum Reason: String, Equatable, Sendable {
        case noEvents = "no transcription events"
        case emptyOnly = "only empty transcripts"
    }

    public enum Action: Equatable, Sendable {
        case none
        case restart(Reason)
    }

    /// - Parameters:
    ///   - sinceAnyEvent: seconds since the last transcription event of any
    ///     kind (partial, final or empty), or since Speech was (re)started.
    ///   - sinceNonEmpty: seconds since the last non-empty transcript, or
    ///     since Speech was (re)started.
    ///   - speechStarted: Speech reports `.started`.
    ///   - sessionStarted: the DeviceSession is `.started` (not paused).
    ///   - pausedByHost: the host paused Speech on purpose (doff, fold, heat)
    ///     or a restart is already in progress; never fight that.
    public static func action(
        sinceAnyEvent: TimeInterval?,
        sinceNonEmpty: TimeInterval?,
        speechStarted: Bool,
        sessionStarted: Bool,
        pausedByHost: Bool
    ) -> Action {
        guard speechStarted, sessionStarted, !pausedByHost else { return .none }
        if let sinceAnyEvent, sinceAnyEvent > noEventLimit { return .restart(.noEvents) }
        if let sinceNonEmpty, sinceNonEmpty > emptyOnlyLimit { return .restart(.emptyOnly) }
        return .none
    }

    /// Speech that stopped while the session was paused is not restarted by
    /// its own stop handler; restart it when the session is started again,
    /// unless the host paused it.
    public static func shouldRestartAfterSessionResumes(
        speechStopped: Bool,
        pausedByHost: Bool
    ) -> Bool {
        speechStopped && !pausedByHost
    }
}
