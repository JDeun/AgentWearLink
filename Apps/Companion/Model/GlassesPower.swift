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
    /// Maximum age of an SDK DeviceState callback accepted for a release.
    /// These are application policy defaults, not Meta safety thresholds.
    public static let maximumObservationAge: TimeInterval = 180
    public static func hasFreshObservation(_ observedAt: Date?, after: Date? = nil, now: Date) -> Bool {
        guard let observedAt, observedAt <= now,
              now.timeIntervalSince(observedAt) <= maximumObservationAge else { return false }
        if let after, observedAt <= after { return false }
        return true
    }

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
        now: Date,
        observedAt: Date? = nil
    ) -> Bool {
        switch hold {
        case let .coolingDown(since):
            guard now.timeIntervalSince(since) >= minimumHold,
                  hasFreshObservation(observedAt, after: since, now: now) else { return false }
            // Meta: CRITICAL and above is unusable, SEVERE throttles
            // everything; MODERATE or cooler is safe to start again.
            return thermal != .unknown && thermal <= .moderate
        case let .charging(since, held):
            guard now.timeIntervalSince(since) >= minimumHold,
                  hasFreshObservation(observedAt, after: since, now: now) else { return false }
            guard thermal < .severe, let battery, (0...100).contains(battery),
                  battery > ConnectionSignals.criticalBattery else { return false }
            if charging { return true }
            if let held { return battery >= held + batteryRise }
            return battery > GlassesBatteryPolicy.lowThreshold
        case let .update(target, since):
            // A new app build never arrives by waiting.
            guard target != .companionApp else { return false }
            return now.timeIntervalSince(since) >= updateRetry
        }
    }

    /// "다시 시작", the Start Listening intent or "Hey Meta, start …": the
    /// wearer asks explicitly. Power/heat holds cannot be overridden without
    /// observed recovery; update prompts retain their existing behavior.
    public static func clearsOnUserRequest(_ hold: GlassesHold) -> Bool {
        if case .update = hold { return true }
        return false
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
        // Unknown is not cooling. Never downgrade an existing stage on
        // missing telemetry, and interrupt any pending release dwell.
        guard level != .unknown else {
            belowSince = nil
            return nil
        }
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

/// Local camera hold is separate from a terminal session hold. A refused
/// snapshot does not prove that a healthy independent voice channel is down.
public enum CameraPowerPolicy {
    // Vendor-free policy so the model unit-test target never links Meta SDK.
    public enum Refusal: Sendable {
        case thermalHot, batteryLow, peakPowerLimit, deviceHealthCritical, streamFailed
    }

    public static func hold(for failure: Refusal, battery: Int?, now: Date) -> GlassesHold? {
        switch failure {
        case .thermalHot, .peakPowerLimit, .deviceHealthCritical:
            return .coolingDown(since: now)
        case .batteryLow:
            return .charging(since: now, battery: battery)
        case .streamFailed:
            return nil
        }
    }

    public static func allowsCapture(stage: ThermalStageTracker.Stage, localHold: GlassesHold?, sessionHold: GlassesHold?) -> Bool {
        ThermalWorkPolicy.allowsPhoto(stage: stage) && localHold == nil && sessionHold == nil
    }

    public static func blocksReconnect(stage: ThermalStageTracker.Stage, sessionHold: GlassesHold?, battery: Int?, charging: Bool) -> Bool {
        if stage == .shed || sessionHold != nil { return true }
        guard let battery, (0...100).contains(battery) else { return false }
        // Even on a charger, a known critical level is not permission to
        // start a new media session.
        return battery <= ConnectionSignals.criticalBattery
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
