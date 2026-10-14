import AppIntents
import Foundation

/// "Start listening" for Shortcuts automations, e.g. "When the glasses
/// connect over Bluetooth → Start listening", so the session comes back by
/// itself after a reboot or a swipe-kill. Uses only the stored approval.
struct StartListeningIntent: AppIntent {
    static let notification = Notification.Name("dev.agentwearlink.companion.startListening")
    static let title: LocalizedStringResource = "듣기 시작"
    static let description = IntentDescription("저장된 설정으로 안경과 에이전트를 다시 연결하고 듣기 시작해요.")
    // A DAT device session is only proven to start with the app running, so
    // the conservative choice is to open the app.
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        // Persisted first: on a cold launch the notification can fire before
        // the UI subscribes; launch consumes the flag instead.
        StartRequestFlag().mark()
        NotificationCenter.default.post(name: Self.notification, object: nil)
        return .result()
    }
}

struct CompanionShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartListeningIntent(),
            phrases: [
                "\(.applicationName) 듣기 시작",
                "Start listening in \(.applicationName)",
            ],
            shortTitle: "듣기 시작",
            systemImageName: "eyeglasses"
        )
    }
}
