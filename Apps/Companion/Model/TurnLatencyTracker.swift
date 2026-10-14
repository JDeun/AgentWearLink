import Foundation

/// Measures "말 끝 → 답 시작": from the moment a request is forwarded (the
/// final transcript, i.e. the end of speech) to the first reply text.
public struct TurnLatencyTracker: Sendable {
    private var pendingSpeechEnd: Date?
    private var answeredReplies: [String] = []

    public init() {}

    /// The wake gate forwarded a request.
    public mutating func requestForwarded(at date: Date) {
        pendingSpeechEnd = date
    }

    /// Reply text for `replyID` arrived. Returns the latency the first time a
    /// reply starts after a forwarded request; later chunks return nil.
    public mutating func replyText(replyID: String, at date: Date) -> TimeInterval? {
        guard !answeredReplies.contains(replyID) else { return nil }
        answeredReplies.append(replyID)
        if answeredReplies.count > 16 { answeredReplies.removeFirst() }
        guard let start = pendingSpeechEnd else { return nil }
        pendingSpeechEnd = nil
        return max(0, date.timeIntervalSince(start))
    }
}
