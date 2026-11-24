import Foundation

/// Speech "can stop after inactivity, a timeout, or another performance
/// constraint" (Meta Speech docs). A hands-free session must come back on its
/// own, so an unrequested stop is restarted a bounded number of times, the
/// cadence Meta's BirdSpotter sample uses. A successful start refills the budget,
/// so repeated self-stops inside `stormWindow` slow the restarts down instead
/// of fighting a device that sheds Speech for power or heat.
enum MetaDATSpeechRestartPolicy {
    enum ObservedState: Equatable {
        case started
        case stopped
        case transitioning
    }

    enum Action: Equatable {
        case resetAttempts
        case restart(attempt: Int)
        case giveUp
        case none
    }

    static let limit = 3
    static let delay: Duration = .milliseconds(750)
    /// Unrequested stops counted for the backoff.
    static let stormWindow: TimeInterval = 600

    /// The longest backoff: a self-stopping Speech in a quiet room must not
    /// leave the glasses deaf for minutes ("can stop after inactivity").
    static let maximumDelay: Duration = .seconds(30)

    /// 750 ms normally; 10 s from the 4th self-stop in 10 min; 30 s (the cap)
    /// from the 6th. A non-empty transcript clears the count.
    static func restartDelay(recentUnrequestedStops: Int) -> Duration {
        switch recentUnrequestedStops {
        case ..<4: return delay
        case 4...5: return .seconds(10)
        default: return maximumDelay
        }
    }

    /// After the backoff sleep: start only if Speech is still stopped. A
    /// resume or session resume during the wait may have started it already.
    static func shouldStartAfterWait(_ state: ObservedState) -> Bool {
        state == .stopped
    }

    /// A stop delivered this soon after a stall restart issued `stop()` is
    /// that restart's own stop (the state event hops through a Task and can
    /// land after the restart gap), not an unrequested one.
    static let ownStopGrace: TimeInterval = 3

    static func isOwnStop(sinceStallStop: TimeInterval?) -> Bool {
        guard let sinceStallStop else { return false }
        return sinceStallStop >= 0 && sinceStallStop < ownStopGrace
    }

    /// Stop times (seconds, any monotonic base) still inside `stormWindow`.
    static func recent(_ stops: [TimeInterval], now: TimeInterval) -> [TimeInterval] {
        stops.filter { now - $0 < stormWindow }
    }

    /// - Parameter paused: the host deliberately stopped Speech (glasses
    ///   taken off or folded); a stop is then expected and never restarted.
    static func action(for state: ObservedState, attempts: Int, paused: Bool = false) -> Action {
        switch state {
        case .started:
            return .resetAttempts
        case .stopped:
            if paused { return .none }
            return attempts < limit ? .restart(attempt: attempts + 1) : .giveUp
        case .transitioning:
            return .none
        }
    }
}
