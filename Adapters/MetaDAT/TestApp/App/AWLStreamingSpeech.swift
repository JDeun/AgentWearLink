import AgentWearLinkAppleOutput
import AgentWearLinkCore
import Foundation

/// EXPERIMENT (same as the companion app, unit-tested there): splits streaming reply text into speakable sentences so the first one can
/// be spoken while the rest is still arriving.
enum AWLSentenceSplitter {
    static let terminators: Set<Character> = [".", "!", "?", "…", "。", "！", "？"]

    /// Complete sentences in `buffer` and the unfinished remainder. A
    /// sentence ends at a terminator run followed by whitespace, or at a
    /// newline. "3.5", "v1.2" and "..." mid-sentence do not split. A line
    /// that starts with "{" (a possible control object) is only split at its
    /// newline. With `final`, the remainder is returned as a last sentence.
    static func split(_ buffer: String, final: Bool = false) -> (sentences: [String], remainder: String) {
        var sentences: [String] = []
        var current = ""
        var lineStartsWithBrace = false
        var atLineStart = true
        let characters = Array(buffer)
        var index = 0
        func emit() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { sentences.append(trimmed) }
            current = ""
        }
        while index < characters.count {
            let character = characters[index]
            if atLineStart, !character.isWhitespace {
                lineStartsWithBrace = character == "{"
                atLineStart = false
            }
            if character == "\n" {
                emit()
                atLineStart = true
                lineStartsWithBrace = false
                index += 1
                continue
            }
            current.append(character)
            if !lineStartsWithBrace, terminators.contains(character) {
                // Consume the whole run ("...", "?!").
                var end = index + 1
                while end < characters.count, terminators.contains(characters[end]) {
                    current.append(characters[end])
                    end += 1
                }
                if end < characters.count, characters[end].isWhitespace {
                    emit()
                    index = end
                    continue
                }
                index = end
                continue
            }
            index += 1
        }
        if final {
            emit()
            return (sentences, "")
        }
        return (sentences, current)
    }
}

/// Removes gateway TTS control lines (JSON objects on their own line)
/// before speaking.
enum AWLTTSControlFilter {
    static func speakable(_ text: String) -> String? {
        let kept = text
            .components(separatedBy: "\n")
            .filter { !isControlLine($0) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return kept.isEmpty ? nil : kept
    }

    static func isControlLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}"),
              let data = trimmed.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else { return false }
        return true
    }
}



/// Speaks a reply sentence by sentence as text deltas stream in, instead of
/// waiting for the whole reply. Gateway TTS control lines are dropped.
///
/// A reply that arrives after a timeout is still spoken ("parked") unless a
/// newer request has started meanwhile; a newer request always supersedes
/// the older one's remaining speech.
actor AWLStreamingSpeechOutput: InteractionOutputSink {
    private let synthesizer: any SpeechSynthesizing
    private var activeID: InteractionID?
    private var buffer = ""
    private var finished: Set<InteractionID> = []
    private var finishedOrder: [InteractionID] = []
    static let maximumBufferedCharacters = 32_000

    init(synthesizer: any SpeechSynthesizing) {
        self.synthesizer = synthesizer
    }

    func consume(_ event: InteractionEvent) async {
        switch event {
        case let .text(id, delta):
            guard !finished.contains(id) else { return }
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
            let (sentences, remainder) = AWLSentenceSplitter.split(buffer)
            buffer = remainder
            for sentence in sentences { await speak(sentence) }

        case let .turnCompleted(id):
            guard !finished.contains(id) else { return }
            remember(id)
            guard activeID == id else { return }
            let (sentences, _) = AWLSentenceSplitter.split(buffer, final: true)
            buffer = ""
            for sentence in sentences { await speak(sentence) }

        case let .failed(id?, error):
            // A timeout is not final: a late reply for the same request may
            // still arrive and is spoken unless a newer request superseded it.
            if case .timeout = error { return }
            guard !finished.contains(id) else { return }
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

    /// Explicit photo flow (raw agent responses).
    func consume(_ response: AgentResponse) async {
        switch response {
        case let .textDelta(id, text): await consume(.text(id, text))
        case let .completed(id): await consume(.turnCompleted(id))
        case let .failed(id, error): await consume(InteractionEvent.failed(id, error))
        }
    }

    func interrupt(interactionID: InteractionID) async {
        remember(interactionID)
        guard activeID == interactionID else { return }
        await interrupt()
    }

    private func speak(_ sentence: String) async {
        guard let text = AWLTTSControlFilter.speakable(sentence) else { return }
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
