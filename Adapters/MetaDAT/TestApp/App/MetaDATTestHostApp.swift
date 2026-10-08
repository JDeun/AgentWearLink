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
            VStack {
                Text(state)
                    .accessibilityIdentifier("awl-meta-host-state")
                Button("Configure mock still fixture") {
                    Task {
                        do {
                            let imageURL = try MetaDATMockStillFixture.write(
                                to: FileManager.default.temporaryDirectory
                            )
                            _ = try MetaDATMockHostBootstrap.configureCapturedPhotoFixture(
                                fileURL: imageURL
                            )
                            state = "photo-fixture-ready"
                        } catch {
                            state = "photo-fixture-error"
                        }
                    }
                }
                .accessibilityIdentifier("awl-meta-configure-photo-fixture")
                .disabled(!ProcessInfo.processInfo.arguments.contains(
                    MetaDATMockHostBootstrap.launchArgument
                ))
            }
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
