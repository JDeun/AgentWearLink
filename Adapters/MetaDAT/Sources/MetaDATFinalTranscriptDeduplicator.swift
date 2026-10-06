import Foundation

public struct MetaDATDedupTranscript: Sendable, Equatable {
    public let text: String
    public let isFinal: Bool
    public init(text: String, isFinal: Bool) { self.text = text; self.isFinal = isFinal }
}

/// Suppresses repeated final delivery for the same normalized utterance within
/// one active speech turn. Call reset() when a new speech turn/session starts.
public actor MetaDATFinalTranscriptDeduplicator {
    private var delivered: Set<String> = []

    public init() {}

    public func accept(_ transcript: MetaDATDedupTranscript) -> Bool {
        guard transcript.isFinal else { return false }
        let key = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !delivered.contains(key) else { return false }
        delivered.insert(key)
        return true
    }

    public func reset() { delivered.removeAll(keepingCapacity: true) }
}
