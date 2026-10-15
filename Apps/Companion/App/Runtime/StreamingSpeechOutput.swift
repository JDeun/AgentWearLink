import AgentWearLinkAppleOutput
import AgentWearLinkCore
import Foundation

/// Speaks a reply sentence by sentence as text deltas stream in, instead of
/// waiting for the whole reply. Gateway TTS control lines are dropped.
///
/// A reply that arrives after a timeout is still spoken ("parked") unless a
/// newer request has started meanwhile; a newer request always supersedes
/// the older one's remaining speech.
actor StreamingSpeechOutput: InteractionOutputSink {
    private let synthesizer: any SpeechSynthesizing
    private var activeID: InteractionID?
    private var buffer = ""
    private var finished: Set<InteractionID> = []
    private var finishedOrder: [InteractionID] = []
    /// Stopped while waiting: the next reply that starts is not spoken.
    private var skipNextReply = false
    static let maximumBufferedCharacters = 32_000

    init(synthesizer: any SpeechSynthesizing) {
        self.synthesizer = synthesizer
    }

    func consume(_ event: InteractionEvent) async {
        switch event {
        case let .text(id, delta):
            guard !finished.contains(id), !skippedAsStopped(id) else { return }
            if activeID != id {
                if activeID != nil { await synthesizer.stop() }
                activeID = id
                buffer = ""
            }
            buffer += delta
            guard buffer.count <= Self.maximumBufferedCharacters else {
                // Runaway reply: stop rather than read a truncated fragment.
                buffer = ""
                remember(id)
                await synthesizer.stop()
                return
            }
            let (sentences, remainder) = SentenceSplitter.split(buffer)
            buffer = remainder
            for sentence in sentences { await speak(sentence) }

        case let .turnCompleted(id):
            guard !finished.contains(id), !skippedAsStopped(id) else { return }
            remember(id)
            guard activeID == id else { return }
            let (sentences, _) = SentenceSplitter.split(buffer, final: true)
            buffer = ""
            for sentence in sentences { await speak(sentence) }

        case let .failed(id?, error):
            // A timeout is not final: a late reply for the same request may
            // still arrive and is spoken unless a newer request superseded it.
            if case .timeout = error { return }
            guard !finished.contains(id), !skippedAsStopped(id) else { return }
            remember(id)
            guard activeID == id else { return }
            buffer = ""
            activeID = nil
            await synthesizer.stop()

        case let .failed(nil, error):
            if case .device = error { await interrupt() }

        case let .interrupted(id), let .sessionEnded(id):
            if activeID == id { await interrupt() }

        case .sessionStarted, .invocation:
            break
        }
    }

    /// The wearer stopped the reply ("그만" / double tap): the rest of it is
    /// dropped. `awaitingReply`: stopped before any reply text, so the next
    /// reply to start (the stopped request's) is dropped too. The caller
    /// stops the speaker itself.
    func stopCurrentReply(awaitingReply: Bool) {
        if let activeID { remember(activeID) }
        activeID = nil
        buffer = ""
        if awaitingReply { skipNextReply = true }
    }

    /// True once for the first event of a new reply after a stop while
    /// waiting; that reply is remembered as finished.
    private func skippedAsStopped(_ id: InteractionID) -> Bool {
        guard skipNextReply, id != activeID else { return false }
        skipNextReply = false
        remember(id)
        return true
    }

    private func speak(_ sentence: String) async {
        guard let text = TTSControlFilter.speakable(sentence) else { return }
        await synthesizer.speak(text)
    }

    private func interrupt() async {
        if let activeID { remember(activeID) }
        activeID = nil
        buffer = ""
        await synthesizer.stop()
    }

    private func remember(_ id: InteractionID) {
        guard finished.insert(id).inserted else { return }
        finishedOrder.append(id)
        if finishedOrder.count > 64 {
            finished.remove(finishedOrder.removeFirst())
        }
    }
}
