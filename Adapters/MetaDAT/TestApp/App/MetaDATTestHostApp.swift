import SwiftUI
import AgentWearLinkMetaDATIntegration

@main
struct MetaDATTestHostApp: App {
    @State private var state = "host-starting"

    init() {
        guard ProcessInfo.processInfo.arguments.contains(MetaDATMockHostBootstrap.launchArgument) else { return }
        Task {
            do {
                try await MetaDATMockHostBootstrap.configureIfRequested()
            } catch {
                NSLog("[AgentWearLinkMetaDATTestHost] bootstrap failed: \(error)")
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            Text(state)
                .accessibilityIdentifier("awl-meta-host-state")
                .task {
                    guard ProcessInfo.processInfo.arguments.contains(MetaDATMockHostBootstrap.launchArgument) else {
                        state = "host-ready"
                        return
                    }
                    let portFile = ProcessInfo.processInfo.environment[MetaDATMockHostBootstrap.portFileEnvironment]
                    for _ in 0..<100 {
                        if let portFile, FileManager.default.fileExists(atPath: portFile) {
                            state = "host-ready"
                            return
                        }
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    state = "host-error"
                }
        }
    }
}
