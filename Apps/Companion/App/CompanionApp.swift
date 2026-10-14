import SwiftUI

@main
struct CompanionApp: App {
    @StateObject private var runtime = CompanionRuntime()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(runtime)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .task { await runtime.start() }
                .onChange(of: scenePhase) { _, phase in runtime.scenePhaseChanged(phase) }
                .onOpenURL { runtime.handleOpenURL($0) }
                .onReceive(NotificationCenter.default.publisher(for: StartListeningIntent.notification)) { _ in
                    runtime.startListeningFromIntent()
                }
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
