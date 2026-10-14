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

    private static func isSeparator(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { separators.contains($0) }
    }

    private static let separators = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: ",.!?…·~、。，"))
}
