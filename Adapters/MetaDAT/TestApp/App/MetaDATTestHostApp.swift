import SwiftUI
import AgentWearLinkCore
import AgentWearLinkOpenClaw
import AgentWearLinkAppleOutput
import AgentWearLinkMetaDATIntegration
import AgentWearLinkMetaDATTestSupport

@main
struct MetaDATTestHostApp: App {
    @State private var state = "host-starting"

    var body: some Scene {
        WindowGroup {
            Text(state)
                .accessibilityIdentifier("awl-meta-host-state")
                .task {
                    guard ProcessInfo.processInfo.arguments.contains(
                        MetaDATMockHostBootstrap.launchArgument
                    ) else {
                        state = "host-ready"
                        return
                    }

                    do {
                        try await MetaDATMockHostBootstrap.configureIfRequested()

                        guard let portFile = ProcessInfo.processInfo.environment[
                            MetaDATMockHostBootstrap.portFileEnvironment
                        ], !portFile.isEmpty else {
                            state = "host-error"
                            return
                        }

                        for _ in 0..<50 {
                            if FileManager.default.fileExists(atPath: portFile) {
                                state = "host-ready"
                                return
                            }
                            try? await Task.sleep(for: .milliseconds(100))
                        }

                        state = "host-error"
                    } catch {
                        NSLog("[AgentWearLinkMetaDATTestHost] bootstrap failed: \(error)")
                        state = "host-error"
                    }
                }
        }
    }
}
