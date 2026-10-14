#if DEBUG
import AgentWearLinkCore
import Foundation

/// DEBUG-only screenshot fixtures, selected with launch arguments:
///
///     -AWLPreview <name> [-AWLPreviewScroll bottom]
///
/// Names: setup-meta, setup-mic, setup-tailscale, setup-pair-qr,
/// setup-pair-paste, setup-pair-manual, setup-pair-waiting,
/// setup-pair-expired, setup-pair-failed, setup-pair-success,
/// setup-practice-listening, setup-practice-matched,
/// setup-practice-unmatched, home-ok, home-waiting, home-problem,
/// home-revoked, home-speech, repair-<reason> (see `repairReasons`),
/// settings, settings-expanded, settings-reset, settings-reapprove,
/// settings-diagnostics. `-AWLPreviewScroll bottom` renders the lower part
/// of a tall screen. Fixtures freeze the signals and never write to the
/// real settings. None of this is compiled into Release builds.
enum CompanionPreviewFixture {
    struct Plan {
        var settings: CompanionSettings
        var signals: ConnectionSignals
        var setup: SetupProgress
        var metaConfiguration: WearablesLink.Configuration?
        var deviceID: String
        var pairing: CompanionRuntime.PairingPhase = .idle
        var practice = CompanionRuntime.PracticeState()
        var listening = false
        var logLines: [String] = []
    }

    enum GatewayMode { case scan, paste, manual }
    enum SettingsDialog { case reset, reapprove }

    static let repairReasons: [String: AWLChainProblemReason] = [
        "repair-registration": .metaRegistrationMissing,
        "repair-battery": .glassesBatteryCritical,
        "repair-update": .glassesUpdateRequired,
        "repair-microphone": .microphoneDenied,
        "repair-network": .networkUnreachable,
        "repair-gateway": .gatewayUnreachable,
        "repair-pending": .pairingPending,
        "repair-revoked": .pairingRevoked,
        "repair-agent": .agentNotResponding,
    ]

    static var requested: String? { argument(after: "-AWLPreview") }
    static var isActive: Bool { requested != nil }
    static var scrollsToBottom: Bool { argument(after: "-AWLPreviewScroll") == "bottom" }

    static var opensSettings: Bool { requested?.hasPrefix("settings") == true }
    static var opensDiagnostics: Bool { requested == "settings-diagnostics" }
    static var showsDiagnosticsLink: Bool { opensSettings && scrollsToBottom || opensDiagnostics }
    static var expandsFingerprint: Bool {
        requested == "settings-expanded" || (opensSettings && scrollsToBottom)
            || settingsDialog != nil
    }
    static var settingsDialog: SettingsDialog? {
        switch requested {
        case "settings-reset": .reset
        case "settings-reapprove": .reapprove
        default: nil
        }
    }
    static var opensRepair: Bool { requested?.hasPrefix("repair-") == true }

    static var gatewayMode: GatewayMode? {
        switch requested {
        case "setup-pair-qr": .scan
        case "setup-pair-paste": .paste
        case "setup-pair-manual": .manual
        default: nil
        }
    }

    private static func argument(after flag: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    @MainActor
    static func apply(to runtime: CompanionRuntime) -> Bool {
        guard let fixture = requested else { return false }
        runtime.applyPreview(plan(for: fixture))
        return true
    }

    static func plan(for fixture: String) -> Plan {
        let now = Date()
        var settings = CompanionSettings()
        settings.setupCompleted = true
        settings.gatewayURL = "wss://studio.example.ts.net"
        settings.agentName = "Nova"
        settings.telegramEnabled = true
        settings.telegramChatID = "100000000"
        settings.lastReplyAt = now.addingTimeInterval(-180)
        settings.lastReplyLatency = 4.2

        var signals = ConnectionSignals()
        signals.microphone = .granted
        signals.network = .reachable
        signals.gateway = .ok
        signals.glasses = .connected
        signals.glassesBattery = 72
        signals.listening = true
        signals.speechReady = true
        signals.lastReplyAt = settings.lastReplyAt
        signals.lastReplyLatency = settings.lastReplyLatency
        for id in AWLChainLinkID.allCases { signals.checkedAt[id] = now.addingTimeInterval(-12) }

        var plan = Plan(
            settings: settings,
            signals: signals,
            setup: SetupProgress(completed: Set(SetupStep.allCases)),
            metaConfiguration: .configured,
            deviceID: "a1b2c3d4e5f60718293a4b5c6d7e8f9001122334455667788990aabbccddeeff",
            listening: true,
            logLines: [
                "meta configured", "recovery: launch", "speech started", "listening",
                "keep-alive on", "armed by name", "request forwarded (14 chars)",
                "check: ok", "device session lost", "recovery: device session lost", "listening",
            ]
        )

        if fixture.hasPrefix("setup") {
            plan.settings.setupCompleted = false
            plan.settings.lastReplyAt = nil
            plan.settings.lastReplyLatency = nil
            plan.signals = ConnectionSignals()
            plan.listening = false
            var progress = SetupProgress()
            let order: [SetupStep]
            switch fixture {
            case "setup-meta": order = []
            case "setup-mic": order = [.metaRegistration]
            case "setup-tailscale": order = [.metaRegistration, .microphone]
            case _ where fixture.hasPrefix("setup-pair"): order = [.metaRegistration, .microphone, .tailscale]
            default: order = [.metaRegistration, .microphone, .tailscale, .gateway]
            }
            order.forEach { progress.complete($0) }
            plan.setup = progress
            if !fixture.hasPrefix("setup-practice") {
                plan.settings.gatewayURL = fixture == "setup-pair-success" ? settings.gatewayURL : ""
                plan.settings.agentName = fixture == "setup-pair-success" ? "Nova" : ""
            }
            switch fixture {
            case "setup-mic": plan.signals.glasses = .waiting
            case "setup-pair-waiting": plan.pairing = .waitingForApproval
            case "setup-pair-expired": plan.pairing = .failed(.expiredCode)
            case "setup-pair-failed": plan.pairing = .failed(.network)
            case "setup-pair-success": plan.pairing = .succeeded
            case "setup-practice-listening":
                plan.listening = true
            case "setup-practice-matched":
                plan.listening = true
                plan.practice = .init(transcript: "Nova, 안녕", matched: true)
            case "setup-practice-unmatched":
                plan.listening = true
                plan.practice = .init(transcript: "오늘 날씨 어때", matched: false)
            default: break
            }
            return plan
        }

        switch fixture {
        case "home-waiting":
            plan.signals.glasses = .waiting
            plan.signals.glassesBattery = nil
            plan.signals.listening = false
            plan.signals.speechReady = false
            plan.listening = false
        case "home-problem":
            plan.signals.network = .unreachable
            plan.signals.gateway = .unknown
        case "home-revoked":
            plan.signals.gateway = .pairingRevoked
            plan.signals.listening = false
            plan.signals.speechReady = false
            plan.listening = false
        case "home-speech":
            plan.signals.speechReady = false
        default:
            if let reason = repairReasons[fixture] {
                apply(reason, to: &plan.signals)
            }
        }
        return plan
    }

    private static func apply(_ reason: AWLChainProblemReason, to signals: inout ConnectionSignals) {
        switch reason {
        case .metaRegistrationMissing: signals.glasses = .registrationRequired
        case .glassesBatteryCritical: signals.glassesBattery = 3
        case .glassesUpdateRequired: signals.glasses = .updateRequired
        case .microphoneDenied: signals.microphone = .denied
        case .networkUnreachable:
            signals.network = .unreachable
            signals.gateway = .unknown
        case .gatewayUnreachable: signals.gateway = .unreachable
        case .pairingPending: signals.gateway = .pairingPending
        case .pairingRevoked: signals.gateway = .pairingRevoked
        case .agentNotResponding: signals.agentFailing = true
        case .glassesNotConnected, .appNotRunning: break
        }
    }
}
#endif
