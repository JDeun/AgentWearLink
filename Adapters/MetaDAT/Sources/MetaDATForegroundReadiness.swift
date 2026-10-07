public actor MetaDATForegroundReadiness {
    public enum State: Sendable, Equatable {
        case fresh
        case stale
        case reacquiring
    }

    public private(set) var state: State

    /// Readiness must be derived from the host's actual application phase.
    ///
    /// Construction alone is never evidence that camera/private-media state is
    /// fresh. A foreground start therefore begins in `.reacquiring` until the
    /// host completes the concrete reacquisition path; a background start is
    /// immediately `.stale`.
    public init(initialPhase: MetaDATApplicationPhase) {
        switch initialPhase {
        case .foreground:
            state = .reacquiring
        case .background:
            state = .stale
        }
    }

    public func handle(_ phase: MetaDATApplicationPhase) {
        switch phase {
        case .background:
            state = .stale
        case .foreground:
            if state == .stale {
                state = .reacquiring
            }
        }
    }

    public func markReacquired() {
        guard state == .reacquiring else { return }
        state = .fresh
    }
}
