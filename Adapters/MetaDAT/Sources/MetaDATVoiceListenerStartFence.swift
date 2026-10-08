/// Serializes creation of the independent vendor voice channel across
/// actor suspension (MainActor allocation and async channel.start).
struct MetaDATVoiceListenerStartFence: Sendable {
    private(set) var generation: UInt64 = 0
    private(set) var isStarting = false

    mutating func begin() -> UInt64? {
        guard !isStarting else { return nil }
        generation &+= 1
        isStarting = true
        return generation
    }

    mutating func invalidate() {
        generation &+= 1
        isStarting = false
    }

    func owns(_ token: UInt64) -> Bool { generation == token }

    mutating func finish(_ token: UInt64) {
        if owns(token) { isStarting = false }
    }
}
