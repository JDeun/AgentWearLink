import AppIntents
import Foundation

/// "Start listening" for Shortcuts automations, e.g. "When the glasses
/// connect over Bluetooth → Start listening", so the session comes back by
/// itself after a reboot or a swipe-kill. Uses only the stored approval.
struct StartListeningIntent: AppIntent {
    static let notification = Notification.Name("dev.agentwearlink.companion.startListening")
    static let title: LocalizedStringResource = "듣기 시작"
    static let description = IntentDescription("저장된 설정으로 안경과 에이전트를 다시 연결하고 듣기 시작해요.")

    /// How long `perform()` keeps the app running while the session comes up.
    static let waitForListening: TimeInterval = 20

    /// Before iOS 26 the conservative choice is to open the app (a DAT
    /// session is only proven to start with the app running); on a locked
    /// phone that asks for unlock, so the automation stops being hands-free.
    ///
    /// It cannot be made iOS-version dependent: the AppIntents metadata
    /// processor requires a compile-time constant here. On iOS 26+ it is
    /// deprecated in favour of `supportedModes`, which is the declared
    /// behaviour there; which of the two the system honours when both are
    /// present is not verified on hardware, so nothing depends on it:
    /// `perform()` waits for listening either way, and logs the app state it
    /// ran in so a device log shows which one won.
    static let openAppWhenRun = true

    /// iOS 26+: run entirely in the background, so a Shortcuts automation
    /// ("Ray-Ban Meta connected → 듣기 시작", Run Immediately) works with the
    /// phone locked. Starting playback + DAT from this background launch is
    /// still to be verified on hardware.
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    /// No unlock needed: the intent only starts listening with the stored
    /// approval; it reads or changes no user data.
    static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }

    @MainActor
    func perform() async throws -> some IntentResult {
        // Persisted first: on a cold launch before the runtime exists, launch
        // consumes the flag instead.
        StartRequestFlag().mark()
        if let runtime = CompanionRuntime.current {
            runtime.noteIntentRun()
            // The app runs only while perform() does: wait for listening.
            _ = await runtime.startListeningAndWait(timeout: Self.waitForListening)
        } else {
            NotificationCenter.default.post(name: Self.notification, object: nil)
        }
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
