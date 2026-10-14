#if DEBUG
import AgentWearLinkCore
import Foundation

/// DEBUG-only screenshot fixtures, selected with a launch argument:
/// `-AWLPreview home-waiting | home-ok | home-problem | settings | setup`.
/// They freeze the signals and never write to the real settings.
enum CompanionPreviewFixture {
    static var requested: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-AWLPreview"), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }

    static var opensSettings: Bool { requested == "settings" }

    @MainActor
    static func apply(to runtime: CompanionRuntime) -> Bool {
        guard let fixture = requested else { return false }
        let now = Date()
        var settings = CompanionSettings()
        settings.setupCompleted = fixture != "setup"
        settings.gatewayURL = "wss://gateway.example.ts.net"
        settings.agentName = "Nova"
        settings.telegramEnabled = true
        settings.telegramChatID = "100000000"
        settings.lastReplyAt = now.addingTimeInterval(-180)
        settings.lastReplyLatency = 4.2

        var signals = ConnectionSignals()
        signals.microphone = .granted
        signals.network = .reachable
        signals.gateway = .ok
        signals.lastReplyAt = settings.lastReplyAt
        signals.lastReplyLatency = settings.lastReplyLatency
        for id in AWLChainLinkID.allCases { signals.checkedAt[id] = now.addingTimeInterval(-12) }
        switch fixture {
        case "home-ok", "settings":
            signals.glasses = .connected
            signals.glassesBattery = 72
            signals.listening = true
        case "home-problem":
            signals.glasses = .connected
            signals.glassesBattery = 72
            signals.network = .unreachable
            signals.gateway = .unknown
        default:
            signals.glasses = .waiting
        }
        let setup = fixture == "setup" ? SetupProgress() : SetupProgress(completed: Set(SetupStep.allCases))
        runtime.applyPreview(
            signals: signals,
            settings: settings,
            setup: setup,
            metaConfiguration: fixture == "setup" ? .notProvisioned : .configured,
            deviceID: "a1b2c3d4e5f60718293a4b5c6d7e8f9001122334455667788990aabbccddeeff"
        )
        return true
    }
}
#endif
