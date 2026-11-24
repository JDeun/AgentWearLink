import Foundation

/// Default and user-edited wake phrases ("<agent name>, …").
public enum WakePhrases {
    /// Used only until the Gateway reports the agent's name. An empty list
    /// would make `AWLWakePhraseGate` forward every utterance, so there is
    /// always at least one phrase.
    public static func fallback(korean: Bool) -> [String] {
        korean ? ["에이전트", "agent"] : ["agent"]
    }

    /// Whether Korean variants belong in the defaults: the UI (and so most
    /// likely the glasses' speech recognition) is Korean.
    public static var prefersKorean: Bool {
        (Locale.preferredLanguages.first ?? "").hasPrefix("ko")
    }

    /// The agent name plus the variants speech recognition commonly produces.
    /// Hangul names add the vocative ("…야" / "…아") and "헤이 …" only for a
    /// Korean UI; Latin names add "hey …". A Latin name is never mixed with
    /// "헤이": a Korean recognizer writes the name in Hangul anyway, which is
    /// what `spokenName` (the user's Korean pronunciation) is for.
    public static func defaults(forAgentName rawName: String, korean: Bool = prefersKorean) -> [String] {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return fallback(korean: korean) }
        var phrases = [name]
        let compact = name.replacingOccurrences(of: " ", with: "")
        phrases.append(compact)
        if containsHangul(name) {
            if korean, let last = compact.unicodeScalars.last, isHangulSyllable(last) {
                phrases.append(compact + (hasFinalConsonant(last) ? "아" : "야"))
                phrases.append("헤이 " + name)
            }
        } else {
            phrases.append("hey " + name)
        }
        return normalized(phrases)
    }

    /// Defaults for the agent name plus, when given, its Korean pronunciation.
    public static func defaults(agentName: String, spokenName: String, korean: Bool = prefersKorean) -> [String] {
        var phrases = defaults(forAgentName: agentName, korean: korean)
        let spoken = spokenName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !spoken.isEmpty {
            phrases += defaults(forAgentName: spoken, korean: true)
        }
        return normalized(phrases)
    }

    /// A name with no Hangul will likely be written in Hangul by a Korean
    /// recognizer, so setup asks how the user pronounces it.
    public static func needsPronunciation(agentName: String) -> Bool {
        let name = agentName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.isEmpty && !containsHangul(name)
    }

    /// The first word of an ignored utterance ("알프레드 안녕" → "알프레드"),
    /// offered in call practice as a one-tap wake phrase. Nil when the
    /// utterance has no usable word.
    public static func candidate(fromIgnored transcript: String) -> String? {
        let separators = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: ",.!?…·~、。，"))
        let word = transcript
            .components(separatedBy: separators)
            .first { !$0.isEmpty }
        guard let word, word.count >= 2, word.count <= 20 else { return nil }
        return word
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

    static func containsHangul(_ text: String) -> Bool {
        text.unicodeScalars.contains { isHangulSyllable($0) || (0x3131...0x318E).contains($0.value) }
    }

    private static func isHangulSyllable(_ scalar: Unicode.Scalar) -> Bool {
        (0xAC00...0xD7A3).contains(scalar.value)
    }

    private static func hasFinalConsonant(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value - 0xAC00) % 28 != 0
    }
}

/// Korean particles that depend on the last syllable of a dynamic word.
public enum KoreanParticle {
    /// 을 after a final consonant, 를 after a vowel, 을(를) when unknown.
    public static func object(after word: String) -> String {
        guard let last = word.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.last,
              (0xAC00...0xD7A3).contains(last.value) else { return "을(를)" }
        return (last.value - 0xAC00) % 28 == 0 ? "를" : "을"
    }
}
