public actor MetaDATForegroundReadiness {
    public enum State: Sendable, Equatable {
        case fresh
        case stale
        case reacquiring
    }

    public private(set) var state: State

    public init(initialPhase: MetaDATApplicationPhase) {
        switch initialPhase {
        case .background:
            state = .stale
        case .foreground:
            // Host foreground does not prove camera/media readiness. A fresh
            // state is published only after the caller explicitly confirms
            // reacquisition.
            state = .reacquiring
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
