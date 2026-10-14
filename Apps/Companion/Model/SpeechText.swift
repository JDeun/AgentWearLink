import Foundation

/// Splits streaming reply text into speakable sentences so the first one can
/// be spoken while the rest is still arriving.
public enum SentenceSplitter {
    static let terminators: Set<Character> = [".", "!", "?", "…", "。", "！", "？"]

    /// Complete sentences in `buffer` and the unfinished remainder. A
    /// sentence ends at a terminator run followed by whitespace, or at a
    /// newline. "3.5", "v1.2" and "..." mid-sentence do not split. A line
    /// that starts with "{" (a possible control object) is only split at its
    /// newline. With `final`, the remainder is returned as a last sentence.
    public static func split(_ buffer: String, final: Bool = false) -> (sentences: [String], remainder: String) {
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
public enum TTSControlFilter {
    public static func speakable(_ text: String) -> String? {
        let kept = text
            .components(separatedBy: "\n")
            .filter { !isControlLine($0) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return kept.isEmpty ? nil : kept
    }

    public static func isControlLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}"),
              let data = trimmed.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else { return false }
        return true
    }
}

/// While any call is active (phone, FaceTime, VoIP), DAT reconnects are
/// declined by the glasses; retrying in a loop is discouraged. Recover once
/// the last call ends.
public struct CallGate: Equatable, Sendable {
    public enum Change: Equatable, Sendable { case none, callStarted, lastCallEnded }

    public private(set) var callActive = false

    public init(callActive: Bool = false) {
        self.callActive = callActive
    }

    public var allowsReconnect: Bool { !callActive }

    public mutating func update(callActive active: Bool) -> Change {
        defer { callActive = active }
        switch (callActive, active) {
        case (false, true): return .callStarted
        case (true, false): return .lastCallEnded
        default: return .none
        }
    }
}
