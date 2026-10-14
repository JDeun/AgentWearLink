/// Speech "can stop after inactivity, a timeout, or another performance
/// constraint" (Meta Speech docs). A hands-free session must come back on its
/// own, so an unrequested stop is restarted a bounded number of times, the
/// cadence Meta's BirdSpotter sample uses. A successful start refills the budget.
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

    static func action(for state: ObservedState, attempts: Int) -> Action {
        switch state {
        case .started:
            return .resetAttempts
        case .stopped:
            return attempts < limit ? .restart(attempt: attempts + 1) : .giveUp
        case .transitioning:
            return .none
        }
    }
}
