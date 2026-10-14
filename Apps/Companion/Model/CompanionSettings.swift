import Foundation

/// Non-secret settings the companion app keeps across launches.
///
/// Only endpoint metadata and preferences live here (UserDefaults). The
/// approved device grant and the device identity stay in the Keychain, and a
/// Gateway token or setup-code bootstrap token is never persisted at all.
/// EXPERIMENT (default off): how replies duck other audio. Changing the
/// app's audio session while a DAT session is held can end that session
/// (dat-ios #292), so both variants exist only to be measured.
public enum ReplyDuckingMode: String, CaseIterable, Equatable, Sendable {
    /// Replies mix over other audio; the session is never touched.
    case off
    /// AVSpeechSynthesizer manages its own audio session
    /// (`usesApplicationAudioSession = false`).
    case separateSynthesizerSession
    /// Toggle `.duckOthers` on the app's playback session around a reply.
    case toggleDuckOthers
}

public struct CompanionSettings: Equatable, Sendable {
    /// Set once the setup flow finished. Launch then connects automatically.
    public var setupCompleted = false
    /// Validated Gateway WebSocket URL, e.g. `wss://host.tailnet.ts.net`.
    public var gatewayURL: String = ""
    /// User-edited display name for the Gateway host ("게이트웨이 이름").
    /// Empty means "derive from the paired host".
    public var gatewayName: String = ""
    /// Agent display name reported by the Gateway (`agent.identity.get`).
    public var agentName: String = ""
    /// How the user pronounces a non-Korean agent name in Korean
    /// (e.g. "알프레드"), added to the default wake phrases. Optional.
    public var spokenName: String = ""
    /// Phrases that start a request. Empty means "derive from the agent name".
    public var wakePhrases: [String] = []
    /// "안경 호출 받기": listen for the glasses at all.
    public var listenEnabled = true
    /// "텔레그램에 기록": ask the Gateway to post replies to a Telegram chat.
    public var telegramEnabled = false
    public var telegramChatID: String = ""
    /// "짧게 말로 답하기": ask for short, speakable answers.
    public var voiceStyle = true
    /// Optional OpenClaw session key; empty uses the agent's main session.
    public var sessionKey: String = ""
    public var replyDucking: ReplyDuckingMode = .off
    /// Wall-clock time of the last spoken reply, for "마지막 대화 N분 전".
    public var lastReplyAt: Date?
    /// Speech end → first reply text, seconds.
    public var lastReplyLatency: TimeInterval?

    public init() {}

    /// The wake phrases actually used: the user's list, or the defaults for
    /// the agent name when the user has not edited them.
    public var effectiveWakePhrases: [String] {
        effectiveWakePhrases(korean: WakePhrases.prefersKorean)
    }

    public func effectiveWakePhrases(korean: Bool) -> [String] {
        let custom = WakePhrases.normalized(wakePhrases)
        return custom.isEmpty
            ? WakePhrases.defaults(agentName: agentName, spokenName: spokenName, korean: korean)
            : custom
    }

    /// Adds a phrase (e.g. what the recognizer heard in call practice),
    /// keeping the current effective list.
    public mutating func addWakePhrase(_ phrase: String, korean: Bool = WakePhrases.prefersKorean) {
        wakePhrases = WakePhrases.normalized(effectiveWakePhrases(korean: korean) + [phrase])
    }

    /// Name shown for the Gateway hop: the user's name, else the first DNS
    /// label of the paired host. Empty when unknown (the UI says "게이트웨이").
    public var gatewayDisplayName: String {
        let custom = gatewayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return custom.isEmpty ? GatewayAddress.defaultName(forGatewayURL: gatewayURL) : custom
    }

    /// Telegram delivery is only real when switched on and a chat id is valid.
    public var isTelegramDeliveryConfigured: Bool {
        telegramEnabled && CompanionTurnOptions.isTelegramChatID(telegramChatID)
    }
}

/// Persists `CompanionSettings` as individual UserDefaults keys, so a single
/// value can be inspected or reset without a migration.
public struct CompanionSettingsStore {
    public enum Key {
        public static let setupCompleted = "awl.companion.setupCompleted"
        public static let gatewayURL = "awl.companion.gatewayURL"
        public static let agentName = "awl.companion.agentName"
        public static let gatewayName = "awl.companion.gatewayName"
        public static let wakePhrases = "awl.companion.wakePhrases"
        public static let spokenName = "awl.companion.spokenName"
        public static let listenEnabled = "awl.companion.listenEnabled"
        public static let telegramEnabled = "awl.companion.telegramEnabled"
        public static let telegramChatID = "awl.companion.telegramChatID"
        public static let voiceStyle = "awl.companion.voiceStyle"
        public static let sessionKey = "awl.companion.sessionKey"
        public static let replyDucking = "awl.companion.replyDucking"
        public static let lastReplyAt = "awl.companion.lastReplyAt"
        public static let lastReplyLatency = "awl.companion.lastReplyLatency"

        static let all = [
            setupCompleted, gatewayURL, gatewayName, agentName, wakePhrases, spokenName, listenEnabled,
            telegramEnabled, telegramChatID, voiceStyle, sessionKey, replyDucking,
            lastReplyAt, lastReplyLatency,
        ]
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> CompanionSettings {
        var settings = CompanionSettings()
        settings.setupCompleted = defaults.bool(forKey: Key.setupCompleted)
        settings.gatewayURL = defaults.string(forKey: Key.gatewayURL) ?? ""
        settings.agentName = defaults.string(forKey: Key.agentName) ?? ""
        settings.gatewayName = defaults.string(forKey: Key.gatewayName) ?? ""
        settings.wakePhrases = defaults.stringArray(forKey: Key.wakePhrases) ?? []
        settings.spokenName = defaults.string(forKey: Key.spokenName) ?? ""
        settings.listenEnabled = defaults.object(forKey: Key.listenEnabled) as? Bool ?? true
        settings.telegramEnabled = defaults.bool(forKey: Key.telegramEnabled)
        settings.telegramChatID = defaults.string(forKey: Key.telegramChatID) ?? ""
        settings.voiceStyle = defaults.object(forKey: Key.voiceStyle) as? Bool ?? true
        settings.sessionKey = defaults.string(forKey: Key.sessionKey) ?? ""
        settings.replyDucking = defaults.string(forKey: Key.replyDucking)
            .flatMap(ReplyDuckingMode.init(rawValue:)) ?? .off
        settings.lastReplyAt = defaults.object(forKey: Key.lastReplyAt) as? Date
        settings.lastReplyLatency = defaults.object(forKey: Key.lastReplyLatency) as? Double
        // Never trust a "completed" flag without an endpoint to connect to.
        if settings.gatewayURL.isEmpty { settings.setupCompleted = false }
        return settings
    }

    public func save(_ settings: CompanionSettings) {
        defaults.set(settings.setupCompleted, forKey: Key.setupCompleted)
        defaults.set(settings.gatewayURL, forKey: Key.gatewayURL)
        defaults.set(settings.agentName, forKey: Key.agentName)
        defaults.set(settings.gatewayName, forKey: Key.gatewayName)
        defaults.set(settings.wakePhrases, forKey: Key.wakePhrases)
        defaults.set(settings.spokenName, forKey: Key.spokenName)
        defaults.set(settings.listenEnabled, forKey: Key.listenEnabled)
        defaults.set(settings.telegramEnabled, forKey: Key.telegramEnabled)
        defaults.set(settings.telegramChatID, forKey: Key.telegramChatID)
        defaults.set(settings.voiceStyle, forKey: Key.voiceStyle)
        defaults.set(settings.sessionKey, forKey: Key.sessionKey)
        defaults.set(settings.replyDucking.rawValue, forKey: Key.replyDucking)
        defaults.set(settings.lastReplyAt, forKey: Key.lastReplyAt)
        defaults.set(settings.lastReplyLatency, forKey: Key.lastReplyLatency)
    }

    /// "모두 지우고 처음부터": forget every stored preference.
    public func reset() {
        for key in Key.all { defaults.removeObject(forKey: key) }
    }
}
