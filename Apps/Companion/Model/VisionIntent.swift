import Foundation

/// Decides from a forwarded request (wake phrase already removed) whether
/// the wearer is asking about what they are looking at, so the turn takes
/// one photo with the glasses camera.
///
/// Deliberately simple, keyword based, and explained by the cases below:
/// - A Korean demonstrative as its own word ("이거", "이건", "저게", "요거" …)
///   plus an asking word ("뭐", "얼마", "읽", "봐", "맞", "어디" …) is visual.
///   On glasses, "이거" means the thing in front of the wearer, so
///   "이거 얼마야?" takes a photo (a price tag or product is the likely
///   referent); "이거 취소해줘" has no asking word and does not.
///   "이거 뭐야 진짜" (exasperation) still takes a photo: one unneeded
///   photo is cheaper than a missed one, and the agent can ignore it.
/// - A demonstrative glued to a previous word ("내일이거든") is not one.
/// - Explicit seeing phrases ("뭐가 보여", "눈앞에", "사진 찍어") are visual.
/// - "읽어줘" / "봐줘" alone (optionally with "좀") are visual; with an
///   object ("메일 읽어줘", "날씨 봐줘", "일정 좀 봐줘") they are not.
/// - Without any of these ("오늘 일정 뭐야") the turn stays text only.
/// - English: "what is this/that" (only when the sentence ends there or
///   continues with "thing", "called", "one", "here", "in front of me" …, so
///   "what's this week's schedule" stays text), "look at this/that",
///   "what do you see", "what am I looking at", "read this/that", "can you
///   see", "take a photo/picture", "how much is this/that".
public enum VisionIntent {
    public enum Reason: String, Equatable, Sendable {
        case demonstrative
        case seeingPhrase
        case bareLookOrRead
        case english
    }

    /// Nil when the request does not need a photo. The reason is a stable
    /// category for the log (never the text).
    public static func reason(for request: String) -> Reason? {
        let text = normalized(request)
        guard !text.isEmpty else { return nil }
        if seeingPhrases.contains(where: text.contains) { return .seeingPhrase }
        let tokens = text.split(whereSeparator: { $0 == " " }).map(String.init)
        if tokens.contains(where: isDemonstrative), askingWords.contains(where: text.contains) {
            return .demonstrative
        }
        if isBareLookOrRead(tokens) { return .bareLookOrRead }
        if matchesEnglish(text) { return .english }
        return nil
    }

    public static func needsPhoto(_ request: String) -> Bool {
        reason(for: request) != nil
    }

    // MARK: Korean

    static let demonstratives = ["이거", "이건", "이게", "이걸", "이것", "저거", "저건", "저게", "저걸", "저것", "요거", "요건", "요게"]

    static let askingWords = [
        "뭐", "뭔", "무슨", "무엇", "어떤", "얼마", "읽", "봐", "보여", "보이", "알려", "설명", "번역",
        "맞", "어디", "누구", "몇", "어때", "괜찮", "먹어도", "이름", "뜻",
    ]

    static let seeingPhrases = [
        "뭐가 보여", "뭐 보여", "뭐가 보이", "보이는 거", "보이는 게", "보이는 것", "눈앞", "눈 앞",
        "내 앞에", "앞에 뭐", "앞에 있는 거", "앞에 있는 게", "내가 보고 있는", "지금 보고 있는",
        "사진 찍", "사진찍", "사진 보고", "찍어서 보",
    ]

    static func isDemonstrative(_ token: String) -> Bool {
        demonstratives.contains(where: token.hasPrefix)
    }

    /// "읽어줘", "좀 봐줘", "이것 좀 읽어 줘": a look/read request with no
    /// other object.
    static func isBareLookOrRead(_ tokens: [String]) -> Bool {
        let fillers: Set<String> = ["좀", "please"]
        let joined = tokens.filter { !fillers.contains($0) }.joined()
        return bareLookOrRead.contains(joined)
    }

    static let bareLookOrRead: Set<String> = [
        "읽어", "읽어줘", "읽어주세요", "읽어줄래", "읽어줄래요", "읽어봐", "읽어봐줘", "읽어볼래",
        "봐줘", "봐주세요", "봐줄래", "봐줄래요", "봐봐", "봐봐줘",
    ]

    // MARK: English

    static let englishAnywhere = [
        "look at this", "look at that", "what do you see", "what can you see", "what am i looking at",
        "can you see this", "can you see that", "do you see this", "do you see that",
        "take a photo", "take a picture", "in front of me",
    ]

    static let englishDeictic = [
        "what is this", "what's this", "what is that", "what's that", "how much is this", "how much is that",
        "read this", "read that", "what does this say", "what does that say", "is this", "is that",
    ]

    /// Words that may follow a deictic phrase and keep it about the scene.
    static let englishContinuations = [
        "thing", "called", "one", "here", "there", "in front of me", "i'm looking at", "i am looking at",
        "for me", "to me", "out", "please", "say", "plant", "sign", "building", "bird", "dog", "food",
        "safe", "ripe", "real",
    ]

    static func matchesEnglish(_ text: String) -> Bool {
        if englishAnywhere.contains(where: { containsWords(text, $0) }) { return true }
        for phrase in englishDeictic {
            var searchStart = text.startIndex
            while let range = text.range(of: phrase, range: searchStart..<text.endIndex) {
                searchStart = range.upperBound
                guard isWordBoundary(text, before: range.lowerBound) else { continue }
                let rest = text[range.upperBound...].trimmingCharacters(in: .whitespaces)
                // "is this/that" alone is too common ("is that right"); it
                // counts only with a scene word after it ("is this safe").
                let bareAllowed = !phrase.hasPrefix("is ")
                if rest.isEmpty { if bareAllowed { return true } else { continue } }
                if englishContinuations.contains(where: { rest.hasPrefix($0) }) { return true }
            }
        }
        return false
    }

    static func containsWords(_ text: String, _ phrase: String) -> Bool {
        var searchStart = text.startIndex
        while let range = text.range(of: phrase, range: searchStart..<text.endIndex) {
            if isWordBoundary(text, before: range.lowerBound), isWordBoundary(text, after: range.upperBound) {
                return true
            }
            searchStart = range.upperBound
        }
        return false
    }

    static func isWordBoundary(_ text: String, before index: String.Index) -> Bool {
        index == text.startIndex || text[text.index(before: index)] == " "
    }

    static func isWordBoundary(_ text: String, after index: String.Index) -> Bool {
        index == text.endIndex || text[index] == " "
    }

    /// Lowercased, curly apostrophes straightened, punctuation to spaces,
    /// whitespace collapsed. Korean particles stay attached to their word.
    static func normalized(_ text: String) -> String {
        let straightened = text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
        let mapped = straightened.unicodeScalars.map { scalar -> Character in
            if scalar == "'" { return "'" }
            if CharacterSet.punctuationCharacters.contains(scalar) || CharacterSet.symbols.contains(scalar)
                || CharacterSet.whitespacesAndNewlines.contains(scalar) {
                return " "
            }
            return Character(scalar)
        }
        return String(mapped).split(separator: " ").joined(separator: " ")
    }
}
