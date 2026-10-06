import SwiftUI
import AgentWearLinkMetaDATIntegration

@main
struct MetaDATTestHostApp: App {
    @State private var bootstrapError: String?

    var body: some Scene {
        WindowGroup {
            VStack(spacing: 12) {
                Text("AgentWearLink Meta DAT Test Host")
                Text(bootstrapError == nil ? "host-ready" : "host-error")
                    .accessibilityIdentifier("awl-meta-host-state")
            }
            .task {
                do {
                    try await MetaDATMockHostBootstrap.configureIfRequested()
                } catch {
                    bootstrapError = String(describing: error)
                }
            }
        }
    }
}
