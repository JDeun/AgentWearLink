import Foundation

/// A single temple tap (or capture press) pauses a running DAT session and
/// is never delivered to the app; there is no `resume()`, only a second tap
/// (dat-ios #312). Left alone the agent stays deaf with no cue. This policy
/// decides when to give up waiting for that second tap and recreate the
/// session (stop + new session, like dashhound), so the agent listens again
/// by itself. Tap-and-hold stops the session and is handled by the normal
/// unexpected-stop recovery, not here.
///
/// Constants (no setting):
/// - `grace` 6 s: long enough for a deliberate second tap to resume first.
/// - A recreated session paused again within `repauseWindow` (30 s) waits
///   `repauseGrace` (20 s): the wearer may really want it paused.
/// - At most `budgetLimit` (5) recreates per `budgetWindow` (10 min); then
///   recreating stops until the next fresh event (don/unfold, foreground,
///   Start Listening).
public struct DevicePausePolicy: Equatable, Sendable {
    public static let grace: TimeInterval = 6
    public static let repauseWindow: TimeInterval = 30
    public static let repauseGrace: TimeInterval = 20
    public static let budgetWindow: TimeInterval = 600
    public static let budgetLimit = 5

    public struct Inputs: Equatable, Sendable {
        /// When the device paused the session (or when waiting restarted
        /// after a fresh event); nil when not paused.
        public var pausedSince: Date?
        /// Glasses worn and unfolded.
        public var worn: Bool
        public var callActive: Bool
        /// Cooling down, waiting for charge or an update.
        public var held: Bool
        public var listeningWanted: Bool

        public init(pausedSince: Date?, worn: Bool, callActive: Bool, held: Bool, listeningWanted: Bool) {
            self.pausedSince = pausedSince
            self.worn = worn
            self.callActive = callActive
            self.held = held
            self.listeningWanted = listeningWanted
        }
    }

    public enum Reason: String, Equatable, Sendable {
        case notPaused = "not paused"
        case notWanted = "listening off"
        /// Off or folded: a doff/fold pause, not a tap.
        case notWorn = "glasses off or folded"
        /// The call gate rebuilds the session when the last call ends.
        case call
        case held = "reconnect held"
        case budgetExhausted = "too many recreates"
    }

    public enum Decision: Equatable, Sendable {
        case wait(until: Date)
        case recreateNow
        case dontRecreate(Reason)
    }

    /// Recreates started (for the budget).
    public private(set) var recreates: [Date] = []
    /// When the last recreated session was listening again.
    public private(set) var lastRecreatedListeningAt: Date?
    /// Budget used up; only a fresh event clears it.
    public private(set) var exhausted = false

    public init() {}

    /// Whether the pause looks like the wearer's tap, worth a cue.
    public static func cuesPause(_ inputs: Inputs) -> Bool {
        inputs.pausedSince != nil && inputs.listeningWanted && inputs.worn && !inputs.callActive && !inputs.held
    }

    /// Seconds to wait after a pause that started at `pausedSince`.
    public func grace(pausedSince: Date) -> TimeInterval {
        if let up = lastRecreatedListeningAt, pausedSince.timeIntervalSince(up) < Self.repauseWindow {
            return Self.repauseGrace
        }
        return Self.grace
    }

    public mutating func decide(_ inputs: Inputs, now: Date) -> Decision {
        guard let pausedSince = inputs.pausedSince else { return .dontRecreate(.notPaused) }
        guard inputs.listeningWanted else { return .dontRecreate(.notWanted) }
        guard !inputs.callActive else { return .dontRecreate(.call) }
        guard !inputs.held else { return .dontRecreate(.held) }
        guard inputs.worn else { return .dontRecreate(.notWorn) }
        recreates = recreates.filter { now.timeIntervalSince($0) < Self.budgetWindow }
        if exhausted || recreates.count >= Self.budgetLimit {
            exhausted = true
            return .dontRecreate(.budgetExhausted)
        }
        let deadline = pausedSince.addingTimeInterval(grace(pausedSince: pausedSince))
        return now < deadline ? .wait(until: deadline) : .recreateNow
    }

    public mutating func recreated(at date: Date) {
        recreates.append(date)
    }

    public mutating func recreatedListening(at date: Date) {
        lastRecreatedListeningAt = date
    }

    /// Don/unfold, foreground or Start Listening: the wearer is engaged, so
    /// the budget starts over.
    public mutating func freshEvent() {
        exhausted = false
        recreates = []
        lastRecreatedListeningAt = nil
    }
}
