public actor MetaDATForegroundReadiness {
    public enum State: Sendable, Equatable { case fresh, stale, reacquiring }
    public private(set) var state: State = .fresh
    public init() {}
    public func handle(_ phase: MetaDATApplicationPhase) {
        switch phase { case .background: state = .stale; case .foreground: if state == .stale { state = .reacquiring } }
    }
    public func markReacquired() { guard state == .reacquiring else { return }; state = .fresh }
}
