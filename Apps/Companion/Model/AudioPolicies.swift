import Foundation

/// Where audio would currently play, independent of AVFoundation types.
public enum AudioOutputKind: Equatable, Sendable {
    case bluetoothA2DP
    case bluetoothLE
    case headphones
    /// Bluetooth hands-free (call quality, takes the glasses mic).
    case bluetoothHFP
    case builtInSpeaker
    case builtInReceiver
    case other
}

public enum AudioRoutePolicy {
    /// Replies are spoken only into the ear: glasses over A2DP/LE or
    /// headphones. Never out of the iPhone speaker (a locked phone in a
    /// pocket or on a desk would read private replies aloud).
    public static func canSpeakAloud(outputs: [AudioOutputKind], allowHandsFree: Bool = false) -> Bool {
        outputs.contains { [.bluetoothA2DP, .bluetoothLE, .headphones].contains($0) || (allowHandsFree && $0 == .bluetoothHFP) }
    }
}

/// What the app does after an audio-session event.
public enum AudioEventPolicy {
    public enum Event: Equatable, Sendable {
        case interruptionBegan
        case interruptionEnded
        case mediaServicesReset
        case routeChanged
    }

    public struct Actions: Equatable, Sendable {
        public var restartKeepAlive = false
        /// Rebuild the DAT session now (a phone call ends it on current
        /// firmware), instead of waiting for the backoff.
        public var recoverSessionNow = false
        public var recreateSynthesizer = false
    }

    public static func actions(for event: Event, listeningWanted: Bool) -> Actions {
        var actions = Actions()
        guard listeningWanted else { return actions }
        switch event {
        case .interruptionBegan:
            break
        case .interruptionEnded:
            // Regardless of shouldResume: the system may not set it after a call.
            actions.restartKeepAlive = true
            actions.recoverSessionNow = true
        case .mediaServicesReset:
            actions.restartKeepAlive = true
            actions.recoverSessionNow = true
            actions.recreateSynthesizer = true
        case .routeChanged:
            actions.restartKeepAlive = true
        }
        return actions
    }
}

/// The echo-guard window. While replies are spoken (possibly several queued
/// sentences) the wake gate ignores everything; each queued sentence extends
/// the estimated end (in case a finish callback never comes), plus a tail.
/// After the last one finishes, only reply-like text is dropped, for as long
/// as the follow-up window that opens after a reply: a late echo final must
/// never reach an armed gate as a request (self-talk loop).
public struct EchoWindow: Equatable, Sendable {
    public static let secondsPerCharacter = 0.18
    public static let tail: TimeInterval = 4
    /// After speech ends, reply-like text is dropped this long: at least the
    /// tail, and the whole follow-up window.
    public static var echoFilter: TimeInterval { max(tail, FollowUpWindow.seconds) }
    /// A one-character transcript ("네", "응") is dropped only this soon
    /// after the reply, and only if the reply contained that character.
    public static let singleCharacterGuard: TimeInterval = 1
    /// Cap per utterance, so a lost callback cannot mute the gate for long.
    public static let maximumEstimate: TimeInterval = 120

    public private(set) var pendingUtterances = 0
    private var speechEnd: Date?
    /// While speech is pending: the estimated end plus the tail.
    private var pendingUntil: Date?
    /// When the last utterance finished.
    private var finishedAt: Date?
    /// What was spoken in the current window, to recognise its echo
    /// afterwards without dropping the wearer's follow-up.
    private var spoken = ""

    public init() {}

    public mutating func beganSpeaking(_ text: String, at now: Date) {
        if pendingUtterances == 0, !isFiltering(at: now) { spoken = "" }
        spoken += Self.canonical(text)
        let estimate = min(Double(text.count) * Self.secondsPerCharacter, Self.maximumEstimate)
        let start = max(speechEnd ?? now, now)
        speechEnd = start.addingTimeInterval(estimate)
        pendingUtterances += 1
        pendingUntil = speechEnd?.addingTimeInterval(Self.tail)
        finishedAt = nil
    }

    /// One utterance finished or was cancelled.
    public mutating func finishedSpeaking(at now: Date) {
        pendingUtterances = max(0, pendingUtterances - 1)
        guard pendingUtterances == 0 else { return }
        speechEnd = nil
        pendingUntil = nil
        finishedAt = now
    }

    /// True while a reply is (believed to be) playing: everything is dropped.
    public func isSpeechPending(at now: Date) -> Bool {
        guard pendingUtterances > 0, let pendingUntil else { return false }
        return now < pendingUntil
    }

    private func isFiltering(at now: Date) -> Bool {
        if isSpeechPending(at: now) { return true }
        guard let finishedAt else { return false }
        return now < finishedAt.addingTimeInterval(Self.echoFilter)
    }

    /// Any suppression in effect (pending speech or the echo filter).
    public func suppresses(at now: Date) -> Bool {
        isFiltering(at: now)
    }

    /// While a reply is being spoken everything is dropped. Afterwards, for
    /// `echoFilter`, only a transcript that looks like the reply itself is:
    /// the wearer's follow-up right after the reply must get through.
    public func suppresses(_ transcript: String, at now: Date) -> Bool {
        if isSpeechPending(at: now) { return true }
        guard isFiltering(at: now) else { return false }
        let heard = Self.canonical(transcript)
        if heard.count < 2 {
            // "네" / "응": the most common answer to the agent's question.
            guard let char = heard.first, spoken.contains(char), let finishedAt else { return heard.isEmpty }
            return now.timeIntervalSince(finishedAt) < Self.singleCharacterGuard
        }
        return Self.looksLikeEcho(transcript, of: spoken)
    }

    static func canonical(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }.map(Character.init))
    }

    /// Share of the transcript's character pairs that occur in the spoken
    /// text; recognisers re-split and drop words, so whole-string equality
    /// is too strict.
    static func looksLikeEcho(_ transcript: String, of spoken: String) -> Bool {
        let heard = Array(canonical(transcript))
        guard heard.count >= 2 else { return !heard.isEmpty && spoken.contains(heard[0]) }
        let source = Array(spoken)
        guard source.count >= 2 else { return false }
        var pairs = Set<String>()
        for index in 0..<(source.count - 1) { pairs.insert(String(source[index...index + 1])) }
        var hits = 0
        for index in 0..<(heard.count - 1) where pairs.contains(String(heard[index...index + 1])) { hits += 1 }
        return Double(hits) / Double(heard.count - 1) >= 0.6
    }
}
