import Foundation

/// Default and user-edited wake phrases ("<agent name>, …").
public enum WakePhrases {
    /// Used only until the Gateway reports the agent's name. An empty list
    /// would make `AWLWakePhraseGate` forward every utterance, so there is
    /// always at least one phrase.
    public static let fallback = ["에이전트", "agent"]

    /// The agent name plus the variants speech recognition commonly produces:
    /// without spaces, a Korean vocative ("…야" / "…아") and "hey/헤이 …".
    public static func defaults(forAgentName rawName: String) -> [String] {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return fallback }
        var phrases = [name]
        let compact = name.replacingOccurrences(of: " ", with: "")
        phrases.append(compact)
        if let last = compact.unicodeScalars.last, isHangulSyllable(last) {
            phrases.append(compact + (hasFinalConsonant(last) ? "아" : "야"))
            phrases.append("헤이 " + name)
        } else {
            phrases.append("hey " + name)
            phrases.append("헤이 " + name)
        }
        return normalized(phrases)
    }

    /// Trims, drops empties and case-insensitive duplicates, keeps order.
    public static func normalized(_ phrases: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for phrase in phrases {
            let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    /// Parses the comma- or newline-separated text field in Settings.
    public static func parse(_ text: String) -> [String] {
        normalized(text.components(separatedBy: CharacterSet(charactersIn: ",\n")))
    }

    private static func isHangulSyllable(_ scalar: Unicode.Scalar) -> Bool {
        (0xAC00...0xD7A3).contains(scalar.value)
    }

    private static func hasFinalConsonant(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value - 0xAC00) % 28 != 0
    }
}
