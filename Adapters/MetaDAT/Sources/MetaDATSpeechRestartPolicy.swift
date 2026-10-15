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

    /// 750 ms normally; 60 s from the 4th self-stop in 10 min; 300 s from the 6th.
    static func restartDelay(recentUnrequestedStops: Int) -> Duration {
        switch recentUnrequestedStops {
        case ..<4: return delay
        case 4...5: return .seconds(60)
        default: return .seconds(300)
        }
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
