struct MetaDATApplicationOwnershipState: Sendable, Equatable {
    private(set) var phase: MetaDATApplicationPhase

    init(initialPhase: MetaDATApplicationPhase) {
        self.phase = initialPhase
    }

    var permitsSessionAcquisition: Bool {
        phase == .foreground
    }

    /// Returns true when the transition crosses the private-media retirement
    /// boundary. Repeated callbacks are idempotent.
    mutating func transition(
        to nextPhase: MetaDATApplicationPhase
    ) -> Bool {
        guard nextPhase != phase else { return false }
        phase = nextPhase
        return nextPhase == .background
    }
}
