import AgentWearLinkOpenClaw
import Foundation

/// Whether the voice session (and its keep-alive) should exist at all.
public enum ListeningPolicy {
    /// Listening runs after setup, or during the setup call practice, and
    /// only while "안경 호출 받기" is on.
    public static func wantsListening(setupCompleted: Bool, listenEnabled: Bool, practicing: Bool) -> Bool {
        listenEnabled && (setupCompleted || practicing)
    }
}

/// What a live voice session should do after a periodic watch tick.
public enum VoiceSessionWatch {
    public enum Action: Equatable, Sendable {
        case keep
        /// Retire it and let silent recovery build a fresh one.
        case reconnect
        /// The stored approval is gone: retire, stop recovery, ask to re-approve.
        case stopNeedsApproval
    }

    /// Health failures in a row before a still-"ready" session is replaced.
    public static let failuresBeforeReconnect = 2
    /// The supervisor's own reconnect gets this many ticks before we step in.
    public static let reconnectingTicksBeforeReplace = 4

    public static func decide(
        connection: GatewayConnectionState,
        healthFailure: GatewayFailure?,
        consecutiveFailures: Int
    ) -> Action {
        if healthFailure == .pairingRevoked { return .stopNeedsApproval }
        switch connection {
        case .ready:
            guard healthFailure != nil else { return .keep }
            return consecutiveFailures >= failuresBeforeReconnect ? .reconnect : .keep
        case .connecting, .authenticating:
            return .keep
        case .reconnecting:
            return consecutiveFailures >= reconnectingTicksBeforeReplace ? .reconnect : .keep
        case .disconnected, .failed:
            // The supervisor stopped for good (e.g. a rejected grant or a
            // non-retryable pairing pause): it will not come back by itself.
            return .reconnect
        }
    }
}

/// Retry schedule while a pairing request waits for approval on the host.
public enum PairingRetry {
    public enum Next: Equatable, Sendable { case retry, codeExpired, timedOut }

    public static let interval: TimeInterval = 3
    public static let maximumWait: TimeInterval = 10 * 60

    public static func next(now: Date, startedAt: Date, codeExpiresAt: Date?) -> Next {
        // A one-time setup code past its expiry can never be approved; say so
        // instead of resending it until the generic timeout.
        if let codeExpiresAt, now >= codeExpiresAt { return .codeExpired }
        if now.timeIntervalSince(startedAt) >= maximumWait { return .timedOut }
        return .retry
    }
}

/// Result of looking for the approved device grant in the Keychain.
public enum GrantStatus: Equatable, Sendable {
    case approved
    case missing
    /// The Keychain could not be read (e.g. before the first unlock after a
    /// reboot). Not a revocation: retry later.
    case unavailable
}

/// A Start Listening request from the App Intent, persisted so a cold launch
/// that posts it before the UI subscribes still honours it.
public struct StartRequestFlag {
    public static let key = "awl.companion.startRequestedAt"
    public static let validity: TimeInterval = 120
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func mark(at date: Date = Date()) {
        defaults.set(date, forKey: Self.key)
    }

    /// True once if a request was marked within `validity`; always clears it.
    public func consume(now: Date = Date()) -> Bool {
        defer { defaults.removeObject(forKey: Self.key) }
        guard let marked = defaults.object(forKey: Self.key) as? Date else { return false }
        let age = now.timeIntervalSince(marked)
        return age >= -5 && age <= Self.validity
    }
}

/// One observed glasses device, independent of the vendor SDK types.
public struct GlassesDeviceObservation: Equatable, Sendable {
    public enum Link: Equatable, Sendable { case connected, connecting, disconnected }
    public var link: Link
    public var updateRequired: Bool
    public var battery: Int?
    public var charging: Bool

    public init(link: Link, updateRequired: Bool = false, battery: Int? = nil, charging: Bool = false) {
        self.link = link
        self.updateRequired = updateRequired
        self.battery = battery
        self.charging = charging
    }
}

public struct GlassesSnapshot: Equatable, Sendable {
    public var glasses: ConnectionSignals.Glasses
    public var battery: Int?
    public var charging: Bool
}

public enum GlassesStateMapper {
    /// Paired glasses that are folded or in the case are listed but not
    /// connected: that is waiting, never "available".
    public static func hasConnectedDevice(_ devices: [GlassesDeviceObservation]) -> Bool {
        devices.contains { $0.link == .connected }
    }

    public static func snapshot(registered: Bool, devices: [GlassesDeviceObservation]) -> GlassesSnapshot {
        guard registered else { return GlassesSnapshot(glasses: .registrationRequired, battery: nil, charging: false) }
        guard let device = devices.first(where: { $0.link == .connected })
            ?? devices.first(where: { $0.link == .connecting })
            ?? devices.first else {
            return GlassesSnapshot(glasses: .waiting, battery: nil, charging: false)
        }
        if device.updateRequired {
            return GlassesSnapshot(glasses: .updateRequired, battery: device.battery, charging: device.charging)
        }
        switch device.link {
        case .connected:
            return GlassesSnapshot(glasses: .connected, battery: device.battery, charging: device.charging)
        case .connecting:
            return GlassesSnapshot(glasses: .connecting, battery: nil, charging: device.charging)
        case .disconnected:
            return GlassesSnapshot(glasses: .waiting, battery: nil, charging: device.charging)
        }
    }
}

/// An in-memory silent mono 16-bit PCM WAV for the keep-alive player.
public enum SilentWAV {
    public static func data(seconds: Double = 1, sampleRate: Int = 8_000) -> Data {
        let samples = max(1, Int(Double(sampleRate) * seconds))
        let dataBytes = samples * 2
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + dataBytes))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16))           // PCM chunk size
        append(UInt16(1))            // PCM
        append(UInt16(1))            // mono
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2)) // byte rate
        append(UInt16(2))            // block align
        append(UInt16(16))           // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(dataBytes))
        data.append(Data(count: dataBytes))
        return data
    }
}
