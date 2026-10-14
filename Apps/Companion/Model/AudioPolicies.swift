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
    public static func canSpeakAloud(outputs: [AudioOutputKind]) -> Bool {
        outputs.contains { [.bluetoothA2DP, .bluetoothLE, .headphones].contains($0) }
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

/// The echo-guard window: the wake gate ignores everything while a reply is
/// spoken and for a short tail afterwards. Started with an estimate (in case
/// the finish callback never comes) and shortened to the real end + tail.
public struct EchoWindow: Equatable, Sendable {
    public static let secondsPerCharacter = 0.18
    public static let tail: TimeInterval = 4
    /// Cap for an estimate, so a lost callback cannot mute the gate for long.
    public static let maximumEstimate: TimeInterval = 120

    public private(set) var until: Date?

    public init() {}

    public mutating func beganSpeaking(_ text: String, at now: Date) {
        let estimate = min(Double(text.count) * Self.secondsPerCharacter, Self.maximumEstimate) + Self.tail
        let end = now.addingTimeInterval(estimate)
        until = max(until ?? end, end)
    }

    /// The synthesizer finished or was cancelled: end at now + tail.
    public mutating func finishedSpeaking(at now: Date) {
        until = now.addingTimeInterval(Self.tail)
    }

    public func suppresses(at now: Date) -> Bool {
        guard let until else { return false }
        return now < until
    }
}
