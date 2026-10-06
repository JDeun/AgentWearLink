/// Marks media readiness stale across a background/foreground boundary.
/// Reacquisition is explicit: foreground alone never resurrects a previous camera/session.
public actor MetaDATForegroundReadiness {
    public enum State: Sendable, Equatable { case fresh, stale, reacquiring }
    public private(set) var state: State = .fresh

    public init() {}

    public func handle(_ phase: MetaDATApplicationPhase) {
        switch phase {
        case .background: state = .stale
        case .foreground:
            if state == .stale { state = .reacquiring }
        }
    }

    public func markReacquired() {
        guard state == .reacquiring else { return }
        state = .fresh
    }
}
