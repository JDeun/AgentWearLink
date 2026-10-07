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
    public static let defaultMaximumBufferedTextBytes = 64 * 1024
    private static let maximumTerminalHistory = 64

    private let synthesizer: any SpeechSynthesizing
    private let maximumBufferedTextBytes: Int
    private var activeInteractionID: InteractionID?
    private var pendingText = ""
    private var pendingTextUTF8Bytes = 0
    private var terminalInteractionIDs: Set<InteractionID> = []
    private var terminalOrder: [InteractionID] = []

    public init(
        synthesizer: any SpeechSynthesizing,
        maximumBufferedTextBytes: Int = AppleSpeechOutput.defaultMaximumBufferedTextBytes
    ) {
        precondition(maximumBufferedTextBytes > 0)
        self.synthesizer = synthesizer
        self.maximumBufferedTextBytes = maximumBufferedTextBytes
    }

    public func consume(_ response: AgentResponse) async {
        switch response {
        case let .textDelta(id, text):
            guard !terminalInteractionIDs.contains(id) else { return }

            if activeInteractionID != id {
                if activeInteractionID != nil {
                    await synthesizer.stop()
                }
                activeInteractionID = id
                pendingText = ""
                pendingTextUTF8Bytes = 0
            }

            let incomingBytes = text.utf8.count
            guard incomingBytes <= maximumBufferedTextBytes - pendingTextUTF8Bytes else {
                // Once a response exceeds the configured bound, discard the entire
                // pending utterance rather than speaking a truncated/private fragment.
                // Mark it terminal so later deltas/completion cannot resurrect it.
                pendingText = ""
                pendingTextUTF8Bytes = 0
                activeInteractionID = nil
                rememberTerminal(id)
                await synthesizer.stop()
                return
            }

            pendingText += text
            pendingTextUTF8Bytes += incomingBytes

        case let .completed(id):
            guard !terminalInteractionIDs.contains(id) else { return }

            let text: String?
            if activeInteractionID == id, !pendingText.isEmpty {
                text = pendingText
                pendingText = ""
                pendingTextUTF8Bytes = 0
            } else {
                text = nil
            }

            rememberTerminal(id)

            if let text {
                await synthesizer.speak(text)
            }

        case let .failed(id, _):
            guard !terminalInteractionIDs.contains(id) else { return }
            rememberTerminal(id)

            guard activeInteractionID == id else { return }
            pendingText = ""
            pendingTextUTF8Bytes = 0
            activeInteractionID = nil
            await synthesizer.stop()
        }
    }

    public func interrupt(interactionID: InteractionID? = nil) async {
        if let interactionID {
            rememberTerminal(interactionID)
            guard interactionID == activeInteractionID else { return }
        } else if let activeInteractionID {
            rememberTerminal(activeInteractionID)
        }

        pendingText = ""
        pendingTextUTF8Bytes = 0
        activeInteractionID = nil
        await synthesizer.stop()
    }

    private func rememberTerminal(_ id: InteractionID) {
        guard terminalInteractionIDs.insert(id).inserted else { return }

        terminalOrder.append(id)
        if terminalOrder.count > Self.maximumTerminalHistory {
            let expired = terminalOrder.removeFirst()
            terminalInteractionIDs.remove(expired)
        }
    }
}
