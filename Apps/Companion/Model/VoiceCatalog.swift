import Foundation

/// The reply voices the wearer can pick from (installed system voices for
/// the reply language), best quality first.
public struct VoiceOption: Equatable, Sendable, Identifiable {
    public enum Quality: Int, Comparable, Sendable {
        case standard = 1, enhanced = 2, premium = 3
        public static func < (a: Quality, b: Quality) -> Bool { a.rawValue < b.rawValue }
    }
    public enum Gender: Sendable { case female, male, unspecified }

    public let id: String
    public let name: String
    public let language: String
    public let quality: Quality
    public let gender: Gender

    public init(id: String, name: String, language: String, quality: Quality, gender: Gender) {
        self.id = id
        self.name = name
        self.language = language
        self.quality = quality
        self.gender = gender
    }
}

public enum VoiceCatalog {
    /// Voices whose language matches `language` (by its primary subtag,
    /// "ko-KR" matches "ko"), best quality first, then by name. Novelty
    /// voices (bells, whispers, robots) are left out.
    public static func options(from voices: [VoiceOption], language: String) -> [VoiceOption] {
        let primary = language.split(separator: "-").first.map(String.init)?.lowercased() ?? language.lowercased()
        return voices
            .filter { $0.language.lowercased().hasPrefix(primary) && !$0.id.contains(".speech.synthesis.voice.") }
            .sorted { ($0.quality, $1.name) > ($1.quality, $0.name) }
    }

    /// iOS reports no gender for the Eloquence voices (Eddy, Flo, …) that
    /// ship for many languages; fill it in from their names.
    public static func gender(for option: VoiceOption) -> VoiceOption.Gender {
        guard option.gender == .unspecified else { return option.gender }
        switch option.name {
        case "Eddy", "Reed", "Rocko", "Grandpa": return .male
        case "Flo", "Sandy", "Shelley", "Grandma": return .female
        default: return .unspecified
        }
    }

    /// The stored choice if it is still installed; nil means system default.
    public static func resolved(_ identifier: String, in options: [VoiceOption]) -> VoiceOption? {
        guard !identifier.isEmpty else { return nil }
        return options.first { $0.id == identifier }
    }
}
