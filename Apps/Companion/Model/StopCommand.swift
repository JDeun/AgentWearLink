import Foundation

/// "그만" / "stop": the wearer stops the reply by voice, like the glasses'
/// own assistant. Only the whole utterance counts (optionally after the
/// wake phrase), so "그만큼 비싸?" or "멈춰 있는 차" never stop anything.
public enum StopCommand {
    public static let words: Set<String> = ["그만", "그만해", "그만해요", "멈춰", "됐어", "됐어요", "조용히", "스톱", "stop"]

    /// Vocatives tolerated between the name and the command ("알프레드야 그만").
    static let particles = ["님아", "님", "씨", "아", "야", "요"]

    public enum Match: Equatable, Sendable {
        /// Only the command ("그만").
        case bare
        /// The wake phrase, then the command ("알프레드 그만").
        case afterWakePhrase
    }

    /// Lowercased letters and digits only (spaces and punctuation dropped).
    public static func normalize(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    public static func match(_ transcript: String, wakePhrases: [String]) -> Match? {
        let heard = normalize(transcript)
        guard !heard.isEmpty else { return nil }
        if words.contains(heard) { return .bare }
        let phrases = wakePhrases.map(normalize).filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        for phrase in phrases where heard.hasPrefix(phrase) {
            let rest = String(heard.dropFirst(phrase.count))
            if words.contains(rest) { return .afterWakePhrase }
            for particle in particles where rest.hasPrefix(particle) {
                if words.contains(String(rest.dropFirst(particle.count))) { return .afterWakePhrase }
            }
        }
        return nil
    }
}

/// Whether a final transcript stops the reply instead of going to the gate.
public enum StopDecision {
    /// - Parameters:
    ///   - replyActive: a reply is being spoken, or the echo window after it
    ///     is still open.
    ///   - echoOfReply: the transcript looks like the spoken reply itself
    ///     (the reply said "그만" and the glasses mic heard it).
    ///   - armed: the gate is armed (name alone, double tap, follow-up).
    public static func shouldStop(
        match: StopCommand.Match?, replyActive: Bool, echoOfReply: Bool, armed: Bool
    ) -> Bool {
        guard let match else { return false }
        if replyActive { return !echoOfReply }
        // Outside a reply a bare "그만" is not addressed to the agent; with
        // the name or an armed gate it is a stop, never a request.
        return match == .afterWakePhrase || armed
    }
}
