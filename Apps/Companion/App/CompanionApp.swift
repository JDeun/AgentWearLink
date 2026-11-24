import SwiftUI
import UIKit

/// Creates the runtime at launch, including a background relaunch by the
/// Bluetooth wake anchor or an App Intent, when no view may ever be created.
final class CompanionAppDelegate: NSObject, UIApplicationDelegate {
    @MainActor lazy var runtime = CompanionRuntime()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        MainActor.assumeIsolated {
            let runtime = self.runtime
            // Reachable from the Start Listening intent, which can run with
            // no view at all (background launch).
            CompanionRuntime.current = runtime
            if launchOptions?[.bluetoothCentrals] != nil { runtime.noteBluetoothRelaunch() }
            // Synchronously, before returning: a CoreBluetooth restore
            // relaunch expects the manager to exist by now.
            runtime.startWakeAnchor()
            Task { await runtime.start() }
        }
        return true
    }
}

@main
struct CompanionApp: App {
    @UIApplicationDelegateAdaptor(CompanionAppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase

    private var runtime: CompanionRuntime { delegate.runtime }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(runtime)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .task { await runtime.start() }
                .onChange(of: scenePhase) { _, phase in runtime.scenePhaseChanged(phase) }
                .onOpenURL { runtime.handleOpenURL($0) }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var runtime: CompanionRuntime

    var body: some View {
        Group {
            if runtime.settings.setupCompleted {
                NavigationStack { HomeView() }
            } else {
                SetupFlowView()
            }
        }
        .background(Theme.background.ignoresSafeArea())
    }
}
