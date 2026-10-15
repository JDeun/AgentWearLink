import Foundation

/// What needs updating when the glasses refuse this app.
public enum GlassesUpdateTarget: String, Equatable, Sendable {
    /// Glasses firmware (DAT `Compatibility.deviceUpdateRequired`).
    case glassesFirmware
    /// The DAT app on the glasses, updated or set up from Meta AI's App
    /// Connections (`datAppOnTheGlassesUpdateRequired`, `dwaUnavailable`).
    case glassesApp
    /// This app's SDK is too old for the glasses (`sdkUpdateRequired`,
    /// `insufficientSDKVersion`): only a new app build helps.
    case companionApp
}

/// Reconnects held back after the glasses ended the session for a reason a
/// quick retry cannot fix. Recovery waits (no session attempts) until the
/// hold is released; it never needs the user to act for heat or battery.
public enum GlassesHold: Equatable, Sendable {
    /// thermalCritical / thermalEmergency / peakPowerShutdown.
    case coolingDown(since: Date)
    /// batteryCritical; `battery` is the level when it happened.
    case charging(since: Date, battery: Int?)
    /// An update is required; retrying before it happened only loops.
    case update(GlassesUpdateTarget, since: Date)

    public var logName: String {
        switch self {
        case .coolingDown: return "cooling down"
        case .charging: return "waiting for charge"
        case let .update(target, _): return "update required (\(target.rawValue))"
        }
    }

    public var updateTarget: GlassesUpdateTarget? {
        if case let .update(target, _) = self { return target }
        return nil
    }
}

public enum GlassesHoldPolicy {
    /// Heat and battery holds last at least this long, even when the state
    /// already looks fine (a peak-power shutdown can come at a normal level,
    /// and a stale reading must not turn the hold into a reconnect loop).
    public static let minimumHold: TimeInterval = 120
    /// Cooling: reconnect at the latest after this, whatever the level says.
    public static let coolingMaximum: TimeInterval = 10 * 60
    /// Charging: try again after this even without a rise (the level may
    /// not be reported while the session is down).
    public static let chargingMaximum: TimeInterval = 30 * 60
    /// The battery rose this many points since the hold: try again.
    public static let batteryRise = 3
    /// Glasses-side updates: try again after this (the user may have updated
    /// in Meta AI without returning to this app).
    public static let updateRetry: TimeInterval = 30 * 60

    public static func shouldRelease(
        _ hold: GlassesHold,
        thermal: SpeechPowerPolicy.Thermal,
        battery: Int?,
        charging: Bool,
        now: Date
    ) -> Bool {
        switch hold {
        case let .coolingDown(since):
            guard now.timeIntervalSince(since) >= minimumHold else { return false }
            // Meta: CRITICAL and above is unusable, SEVERE throttles
            // everything; MODERATE or cooler is safe to start again.
            if thermal != .unknown, thermal <= .moderate { return true }
            return now.timeIntervalSince(since) >= coolingMaximum
        case let .charging(since, held):
            guard now.timeIntervalSince(since) >= minimumHold else { return false }
            if charging { return true }
            if let battery {
                if let held, battery >= held + batteryRise { return true }
                if held == nil, battery > GlassesBatteryPolicy.lowThreshold { return true }
            }
            return now.timeIntervalSince(since) >= chargingMaximum
        case let .update(target, since):
            // A new app build never arrives by waiting.
            guard target != .companionApp else { return false }
            return now.timeIntervalSince(since) >= updateRetry
        }
    }

    /// "다시 시작", the Start Listening intent or "Hey Meta, start …": the
    /// wearer asks explicitly. Heat is never overridden (the glasses would
    /// refuse anyway and get hotter).
    public static func clearsOnUserRequest(_ hold: GlassesHold) -> Bool {
        if case .coolingDown = hold { return false }
        return true
    }

    /// Back in the foreground: the user may have updated in Meta AI.
    public static func clearsOnForeground(_ hold: GlassesHold) -> Bool {
        if case .update = hold { return true }
        return false
    }
}

/// Meta's thermal guidance in stages: LIGHT adds no new load (nothing to
/// change here), MODERATE reduces optional work, SEVERE and above sheds
/// Speech. Stepping down waits `releaseDwell` below the stage, so a level
/// hovering at a boundary does not flap.
public struct ThermalStageTracker: Equatable, Sendable {
    public enum Stage: Int, Comparable, Sendable {
        case normal, reduced, shed

        public static func < (lhs: Stage, rhs: Stage) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public static let releaseDwell: TimeInterval = 60

    public private(set) var stage: Stage = .normal
    private var belowSince: Date?

    public init() {}

    /// Unknown counts as no evidence of heat (it never pauses on its own).
    public static func target(for level: SpeechPowerPolicy.Thermal) -> Stage {
        switch level {
        case .unknown, .normal, .light: return .normal
        case .moderate: return .reduced
        case .severe, .critical, .emergency, .shutdown: return .shed
        }
    }

    /// Returns the new stage when it changed.
    @discardableResult
    public mutating func update(level: SpeechPowerPolicy.Thermal, at now: Date) -> Stage? {
        let target = Self.target(for: level)
        if target > stage {
            stage = target
            belowSince = nil
            return target
        }
        guard target < stage else {
            belowSince = nil
            return nil
        }
        guard let since = belowSince else {
            belowSince = now
            return nil
        }
        guard now.timeIntervalSince(since) >= Self.releaseDwell else { return nil }
        stage = target
        belowSince = nil
        return target
    }
}

/// What MODERATE heat (`reduced`) turns off. Speech keeps listening.
public enum ThermalWorkPolicy {
    /// Thinking ticks and the "listening" cue are optional; the accepted
    /// and failed cues answer the wearer and always play.
    public static func allowsEarcon(_ earcon: Earcon, stage: ThermalStageTracker.Stage) -> Bool {
        stage == .normal || earcon == .accepted || earcon == .failed
    }

    /// A photo turn starts the camera (heat, power): only at normal heat
    /// (thermal unknown, normal or light). Otherwise the turn goes without.
    public static func allowsPhoto(stage: ThermalStageTracker.Stage) -> Bool {
        stage == .normal
    }

    /// Gateway voice clips rendered ahead of the one playing (nil: all).
    public static func gatewayVoicePrefetchLimit(stage: ThermalStageTracker.Stage) -> Int? {
        stage == .normal ? nil : 1
    }

    /// Speech statistics are logged less often.
    public static func reducesSpeechStats(stage: ThermalStageTracker.Stage) -> Bool {
        stage != .normal
    }
}

/// Glasses battery staging. Below `lowThreshold` (not charging) the app
/// says so once and shows a gentle notice; it does NOT stop listening (the
/// owner decides that after measurements; a later "quiet mode" can key off
/// `LowBatteryNotice.active`).
public enum GlassesBatteryPolicy {
    public static let lowThreshold = 15
    /// The notice clears only above this (no flapping at 15/16 %).
    public static let clearAbove = 20

    public static func isLow(battery: Int?, charging: Bool) -> Bool {
        guard let battery, !charging else { return false }
        return battery <= lowThreshold
    }
}

public struct LowBatteryNotice: Equatable, Sendable {
    public private(set) var active = false

    public init() {}

    /// True exactly once when the battery becomes low (log it then).
    /// An unreported level keeps the current state.
    @discardableResult
    public mutating func update(battery: Int?, charging: Bool) -> Bool {
        if active {
            if charging || (battery ?? 0) > GlassesBatteryPolicy.clearAbove { active = false }
            return false
        }
        guard GlassesBatteryPolicy.isLow(battery: battery, charging: charging) else { return false }
        active = true
        return true
    }
}
