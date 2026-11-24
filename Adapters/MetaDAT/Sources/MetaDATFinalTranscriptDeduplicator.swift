import Foundation

public struct MetaDATDedupTranscript: Sendable, Equatable {
    public let text: String
    public let isFinal: Bool
    public init(text: String, isFinal: Bool) { self.text = text; self.isFinal = isFinal }
}

/// Suppresses immediate, consecutive duplicate final delivery without treating
/// an entire DeviceSession as a single utterance. DAT 1.1 TranscriptionResult
/// exposes no stable utterance ID or sequence number; this is a bounded
/// heuristic, not an exactly-once guarantee.
public actor MetaDATFinalTranscriptDeduplicator {
    private let duplicateWindow: Duration
    private let maximumCachedUTF8Bytes: Int
    private var lastFinal: (key: String, acceptedAt: ContinuousClock.Instant)?

    public init(
        duplicateWindow: Duration = .seconds(1),
        maximumCachedUTF8Bytes: Int = 4096
    ) {
        precondition(duplicateWindow > .zero && maximumCachedUTF8Bytes > 0)
        self.duplicateWindow = duplicateWindow
        self.maximumCachedUTF8Bytes = maximumCachedUTF8Bytes
    }

    public func accept(
        _ transcript: MetaDATDedupTranscript,
        now: ContinuousClock.Instant = .now
    ) -> Bool {
        guard transcript.isFinal else { return false }
        let key = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return false }

        if let lastFinal,
           lastFinal.key == key,
           now >= lastFinal.acceptedAt,
           now - lastFinal.acceptedAt < duplicateWindow {
            // Do not extend the window on duplicates: a later intentional
            // repetition must be able to pass even after repeated callbacks.
            return false
        }

        // One bounded cached final, not a session-lifetime set of utterances.
        // Never silently suppress a valid oversized final solely because it
        // cannot be retained for heuristic deduplication.
        if key.utf8.count <= maximumCachedUTF8Bytes {
            lastFinal = (key, now)
        } else {
            lastFinal = nil
        }
        return true
    }

    public func reset() { lastFinal = nil }
}
