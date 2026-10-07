struct MetaDATSelectedDeviceLinkLossGate: Sendable {
    private var hasEstablishedLink: Bool
    private var sessionStarted = false
    private var terminalSignaled = false

    init(initiallyConnected: Bool = false) {
        self.hasEstablishedLink = initiallyConnected
    }

    mutating func markSessionStarted() {
        sessionStarted = true
    }

    /// Returns true exactly once when a non-connected observation represents
    /// loss of a previously established/started path rather than startup state.
    mutating func observe(isConnected: Bool) -> Bool {
        guard !terminalSignaled else { return false }

        if isConnected {
            hasEstablishedLink = true
            return false
        }

        guard hasEstablishedLink || sessionStarted else {
            return false
        }

        terminalSignaled = true
        return true
    }
}
