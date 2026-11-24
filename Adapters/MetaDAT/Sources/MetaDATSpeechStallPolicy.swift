import Foundation

/// Field evidence (iOS DAT 1.0.0 on real Ray-Ban Meta): Speech can stay
/// "started" on a connected session while it stops delivering transcripts,
/// or keeps delivering only empty ones without hearing anything. While it
/// listens it emitted events roughly every 0.3 s even in silence in that
/// field observation. This is not a documented SDK heartbeat. Same-instance
/// stop/start is a bounded heuristic, not proof of deafness.
public enum MetaDATSpeechStallPolicy {
    /// No transcription event of any kind for this long: stalled.
    public static let noEventLimit: TimeInterval = 4
    /// Only empty transcripts for this long: deaf. Silence also yields only
    /// empty transcripts, so a quiet room restarts Speech at this cadence;
    /// that is the price of recovering a deaf Speech. Field log 2026-10-14:
    /// with 180 s, Speech that went deaf after the glasses were put back on
    /// ignored "알프레드, 지금 몇 시야" for minutes; 20 s recovered it.
    public static let emptyOnlyLimit: TimeInterval = 20
    /// Backoff for the empty-only rule: each empty-only restart in a row
    /// doubles the limit up to this cap, and a non-empty transcript resets
    /// it. A quiet room otherwise restarts Speech every 20 s all day
    /// (~180 restarts an hour) while the glasses ASR keeps running.
    public static let emptyOnlyCap: TimeInterval = 300
    /// Right after Speech starts fresh (connect, re-wear, unfold, session
    /// resume) deafness is most likely (field log 2026-10-14), so the 20 s
    /// limit applies for this long regardless of backoff.
    public static let freshStartWindow: TimeInterval = 60

    /// The empty-only limit for the current state.
    public static func emptyOnlyLimit(consecutiveEmptyRestarts: Int, sinceFreshStart: TimeInterval?) -> TimeInterval {
        if let sinceFreshStart, sinceFreshStart < freshStartWindow { return emptyOnlyLimit }
        let factor = pow(2, Double(min(max(consecutiveEmptyRestarts, 0), 10)))
        return min(emptyOnlyLimit * factor, emptyOnlyCap)
    }

    /// Pause between stop() and start() of a stall restart.
    public static let restartGap: Duration = .milliseconds(600)
    /// An asynchronous SDK stop must actually be observed before start.
    public static let stopConfirmationTimeout: Duration = .seconds(3)
    public static let stopConfirmationPoll: Duration = .milliseconds(100)
    /// No callbacks after repeated restarts is not evidence of readiness.
    /// Limit retries until a fresh activation or an actual callback.
    public static let noEventRecoveryLimit = 3
    /// Empty callbacks may represent true silence. Cap speculative recoveries
    /// until actual nonempty evidence or a fresh activation.
    public static let emptyOnlyRecoveryLimit = 3

    public static func canRecoverEmptyOnly(attempts: Int) -> Bool {
        attempts >= 0 && attempts < emptyOnlyRecoveryLimit
    }

    /// Use ingress, not dequeue time. Ignore prior-run or future evidence.
    public static func evidenceAge(
        _ evidence: ContinuousClock.Instant?,
        runStartedAt: ContinuousClock.Instant?,
        now: ContinuousClock.Instant
    ) -> TimeInterval? {
        guard let runStartedAt, runStartedAt <= now else { return nil }
        let reference = max(runStartedAt, evidence ?? runStartedAt)
        guard reference <= now else { return nil }
        let duration = now - reference
        return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    public static func canRecoverNoEvents(attempts: Int) -> Bool {
        attempts >= 0 && attempts < noEventRecoveryLimit
    }

    public enum PostStopAction: Equatable, Sendable {
        case start
        case wait
        case abandon
    }

    public static func postStopAction(
        ownsSpeech: Bool,
        cancelled: Bool,
        hostPaused: Bool,
        sessionStarted: Bool,
        speechStopped: Bool,
        beforeDeadline: Bool
    ) -> PostStopAction {
        guard ownsSpeech, !cancelled, !hostPaused, sessionStarted, beforeDeadline else {
            return .abandon
        }
        return speechStopped ? .start : .wait
    }
    /// How often the adapter checks.
    public static let checkInterval: Duration = .seconds(2)
    /// Speech event counts are logged this often (the activity log holds
    /// only 300 lines; a line every 10 s pushed out session-end lines).
    public static let statsInterval: Duration = .seconds(60)

    /// MODERATE heat (reduced optional work): stats lines this many times
    /// less often.
    public static let reducedStatsStretch = 5

    /// Seconds one stats line covers.
    public static func statsSeconds(reduced: Bool) -> Int64 {
        statsInterval.components.seconds * Int64(reduced ? reducedStatsStretch : 1)
    }

    /// True on the check that completes a stats window (`statsInterval`,
    /// stretched while work is reduced).
    public static func shouldLogStats(afterCheck checks: Int, reduced: Bool = false) -> Bool {
        let perLine = max(1, Int(statsSeconds(reduced: reduced) / checkInterval.components.seconds))
        return checks > 0 && checks % perLine == 0
    }

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
        pausedByHost: Bool,
        emptyOnlyLimit limit: TimeInterval = emptyOnlyLimit
    ) -> Action {
        guard speechStarted, sessionStarted, !pausedByHost else { return .none }
        if let sinceAnyEvent, sinceAnyEvent > noEventLimit { return .restart(.noEvents) }
        if let sinceNonEmpty, sinceNonEmpty > limit { return .restart(.emptyOnly) }
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
