import Foundation

/// Decides which continuously transcribed utterances are requests for the
/// agent. A request must start with a wake phrase (the agent's name), or
/// follow the phrase said on its own, or follow an explicit `arm()` from a
/// gesture. Transcripts inside a suppression window (the app's own spoken
/// reply echoing back into the microphone) are ignored.
///
/// Not thread-safe; own it from one actor.
public final class AWLWakePhraseGate {
    public enum Decision: Equatable, Sendable {
        case forward(String)
        case armed
        case ignore
    }

    private let wakePhrases: [String]
    private let armedWindow: TimeInterval
    private let clock: () -> Date
    private var armedUntil: Date?
    private var suppressedUntil: Date?

    /// - Parameters:
    ///   - wakePhrases: case-insensitive phrases; empty forwards everything.
    ///   - armedWindow: seconds a bare wake phrase or `arm()` stays valid.
    public init(
        wakePhrases: [String],
        armedWindow: TimeInterval = 8,
        clock: @escaping () -> Date = Date.init
    ) {
        self.wakePhrases = wakePhrases
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
        self.armedWindow = armedWindow
        self.clock = clock
    }

    /// The next utterance within the armed window is forwarded.
    public func arm() {
        armedUntil = clock().addingTimeInterval(armedWindow)
    }

    /// Ignore every transcript until `date` (e.g. reply end + echo tail).
    public func suppress(until date: Date) {
        if let current = suppressedUntil, current > date { return }
        suppressedUntil = date
    }

    public func evaluate(_ transcript: String) -> Decision {
        let now = clock()
        if let suppressedUntil, now < suppressedUntil { return .ignore }

        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.trimmingCharacters(in: Self.separators).isEmpty else { return .ignore }
        guard !wakePhrases.isEmpty else { return .forward(text) }

        if let request = stripWakePhrase(from: text) {
            guard !request.isEmpty else {
                arm()
                return .armed
            }
            armedUntil = nil
            return .forward(request)
        }

        if let armedUntil, now <= armedUntil {
            self.armedUntil = nil
            return .forward(text)
        }
        armedUntil = nil
        return .ignore
    }

    private func stripWakePhrase(from text: String) -> String? {
        if let exact = stripExactWakePhrase(from: text) { return exact }
        // Speech recognition spells Korean names inconsistently
        // (알프래드, 앨프레드, 알프레도, 알프레드야): fuzzy-match Hangul phrases.
        for phrase in wakePhrases where AWLHangulFuzzy.containsHangul(phrase) {
            if let request = AWLHangulFuzzy.stripPhrase(phrase, from: text) {
                return request.trimmingCharacters(in: Self.separators).isEmpty ? "" : request
            }
        }
        return nil
    }

    private func stripExactWakePhrase(from text: String) -> String? {
        let lowered = text.lowercased()
        for phrase in wakePhrases where lowered.hasPrefix(phrase) {
            let rest = text.dropFirst(phrase.count)
            // "Alfredo…" is a different word; require a boundary.
            if let next = rest.first, next.isLetter || next.isNumber { continue }
            let request = String(rest.drop { Self.isSeparator($0) })
            return request.trimmingCharacters(in: Self.separators).isEmpty ? "" : request
        }
        return nil
    }

    static func isSeparator(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { separators.contains($0) }
    }

    static let separators = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: ",.!?…·~、。，"))
}

/// Jamo-level fuzzy prefix matching for Hangul wake phrases. Latin phrases
/// keep the exact, word-boundary rule.
enum AWLHangulFuzzy {
    /// Trailing vocatives/particles tolerated after a name.
    static let trailingParticles: [String] = ["님아", "님", "씨", "아", "야", "요"]

    static func containsHangul(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) }
    }

    /// The request after a fuzzy-matched wake phrase, or nil.
    static func stripPhrase(_ phrase: String, from text: String) -> String? {
        let phraseWords = phrase.split(separator: " ").map(String.init)
        guard !phraseWords.isEmpty else { return nil }

        // Take as many leading words of the utterance as the phrase has.
        var index = text.startIndex
        var words: [String] = []
        while words.count < phraseWords.count {
            while index < text.endIndex, AWLWakePhraseGate.isSeparator(text[index]) {
                index = text.index(after: index)
            }
            guard index < text.endIndex else { return nil }
            var end = index
            while end < text.endIndex, !AWLWakePhraseGate.isSeparator(text[end]) {
                end = text.index(after: end)
            }
            words.append(String(text[index..<end]).lowercased())
            index = end
        }
        let rest = String(text[index...]).drop { AWLWakePhraseGate.isSeparator($0) }

        let syllables = phrase.unicodeScalars.filter { (0xAC00...0xD7A3).contains($0.value) }.count
        let target = jamo(phraseWords.joined())
        // Short names allow one jamo edit. Names of 9+ jamo (e.g. 알프레드)
        // allow two: recognizers split a final consonant into a syllable
        // ("알프레드" heard as "아이프레드", field log 2026-10-14).
        let allowed = syllables <= 4 && target.count < 9 ? 1 : 2

        var candidates = [words.joined()]
        if let last = words.last {
            for particle in trailingParticles where last.hasSuffix(particle) && last.count > particle.count + 1 {
                candidates.append((words.dropLast() + [String(last.dropLast(particle.count))]).joined())
            }
        }
        for candidate in candidates where editDistance(jamo(candidate), target, limit: allowed) <= allowed {
            return String(rest)
        }
        return nil
    }

    /// Decomposes Hangul syllables into normalized jamo; other characters
    /// pass through. Commonly confused vowels are merged (ㅐ/ㅔ, ㅒ/ㅖ, ㅓ/ㅗ).
    static func jamo(_ text: String) -> [UInt32] {
        var result: [UInt32] = []
        for scalar in text.unicodeScalars {
            let value = scalar.value
            guard (0xAC00...0xD7A3).contains(value) else {
                result.append(value)
                continue
            }
            let index = value - 0xAC00
            let lead = index / (21 * 28)
            var vowel = (index % (21 * 28)) / 28
            let tail = index % 28
            switch vowel {
            case 1: vowel = 5    // ㅐ → ㅔ
            case 3: vowel = 7    // ㅒ → ㅖ
            case 8: vowel = 4    // ㅗ → ㅓ
            default: break
            }
            result.append(0x1100 + lead)
            result.append(0x1161 + vowel)
            if tail != 0 { result.append(0x11A7 + tail) }
        }
        return result
    }

    /// Levenshtein distance, stopping early once it exceeds `limit`.
    static func editDistance(_ a: [UInt32], _ b: [UInt32], limit: Int) -> Int {
        if abs(a.count - b.count) > limit { return limit + 1 }
        var previous = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var current = [i + 1] + Array(repeating: 0, count: b.count)
            var rowMinimum = current[0]
            for (j, y) in b.enumerated() {
                current[j + 1] = min(previous[j + 1] + 1, current[j] + 1, previous[j] + (x == y ? 0 : 1))
                rowMinimum = min(rowMinimum, current[j + 1])
            }
            if rowMinimum > limit { return limit + 1 }
            previous = current
        }
        return previous[b.count]
    }
}
