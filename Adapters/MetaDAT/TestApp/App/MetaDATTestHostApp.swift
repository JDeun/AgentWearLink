import SwiftUI
import AgentWearLinkMetaDATIntegration

@main
struct MetaDATTestHostApp: App {
    @State private var bootstrapState = "host-starting"

    var body: some Scene {
        WindowGroup {
            VStack(spacing: 12) {
                Text("AgentWearLink Meta DAT Test Host")
                Text(bootstrapState)
                    .accessibilityIdentifier("awl-meta-host-state")
            }
            .task {
                do {
                    try await MetaDATMockHostBootstrap.configureIfRequested()
                    bootstrapState = "host-ready"
                } catch {
                    bootstrapState = "host-error: \(error)"
                }
            }
        }
    }
}
