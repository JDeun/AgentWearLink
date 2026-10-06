import Foundation
import AgentWearLinkCore

public struct MetaDATFinalTranscript: Sendable, Equatable {
    public let text: String
    public let isFinal: Bool
    public init(text: String, isFinal: Bool) { self.text = text; self.isFinal = isFinal }
}

public struct MetaDATFinalTranscriptFilter: Sendable {
    public init() {}
    public func event(for transcript: MetaDATFinalTranscript, interactionID: InteractionID) -> InteractionEvent? {
        guard transcript.isFinal else { return nil }
        let text = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return .text(interactionID, text)
    }
}
