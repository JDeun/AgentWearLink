import AppIntents
import Foundation

/// "Start listening" for Shortcuts automations, e.g. "When Ray-Ban Meta
/// connects over Bluetooth → Start listening", so the app comes back by itself
/// after a reboot or a swipe-kill. Uses only the stored device approval.
struct AWLStartListeningIntent: AppIntent {
    static let notification = Notification.Name("awl.startListening")
    static let title: LocalizedStringResource = "Start listening"
    static let description = IntentDescription(
        "Reconnects the glasses and the agent with the saved settings and starts listening."
    )
    // A DAT device session is only proven to start with the app running;
    // opening it is the conservative choice until background start is tested.
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: Self.notification, object: nil)
        return .result()
    }
}

struct AWLAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AWLStartListeningIntent(),
            phrases: ["Start listening in \(.applicationName)"],
            shortTitle: "Start listening",
            systemImageName: "eyeglasses"
        )
    }
}
