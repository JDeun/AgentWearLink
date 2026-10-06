import AgentWearLinkCore
import Foundation

public protocol SpeechSynthesizing: Sendable {
    func speak(_ text: String) async
    func stop() async
}

/// Bounded, replaceable output lifecycle for Apple hosts.
///
/// The concrete AVSpeechSynthesizer bridge lives in the iOS host. This actor
/// deliberately keeps only the latest pending text and cancels active speech
/// before a replacement, preventing an unbounded spoken-response queue.
public actor AppleSpeechOutput {
    private let synthesizer: any SpeechSynthesizing
    private var activeInteractionID: InteractionID?
    private var pendingText = ""

    public init(synthesizer: any SpeechSynthesizing) {
        self.synthesizer = synthesizer
    }

    public func consume(_ response: AgentResponse) async {
        switch response {
        case let .textDelta(id, text):
            if activeInteractionID != id {
                if activeInteractionID != nil {
                    await synthesizer.stop()
                }
                activeInteractionID = id
                pendingText = ""
            }
            pendingText += text

        case let .completed(id):
            guard activeInteractionID == id, !pendingText.isEmpty else { return }
            let text = pendingText
            pendingText = ""
            await synthesizer.speak(text)

        case let .failed(id, _):
            guard activeInteractionID == id else { return }
            pendingText = ""
            activeInteractionID = nil
            await synthesizer.stop()
        }
    }

    public func interrupt(interactionID: InteractionID? = nil) async {
        guard interactionID == nil || interactionID == activeInteractionID else { return }
        pendingText = ""
        activeInteractionID = nil
        await synthesizer.stop()
    }
}
