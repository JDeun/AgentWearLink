import SwiftUI
import AgentWearLinkMetaDATIntegration

@main
struct AgentWearLinkMetaDATTestHostApp: App {
    init() {
        Task {
            try? await MetaDATMockHostBootstrap.configureIfRequested()
        }
    }

    var body: some Scene {
        WindowGroup {
            Text("AgentWearLink Meta DAT Test Host")
                .accessibilityIdentifier("awl_meta_test_host_ready")
        }
    }
}
