import SwiftUI
import AgentWearLinkMetaDATIntegration

@main
struct MetaDATTestHostApp: App {
    var body: some Scene {
        WindowGroup {
            Text("AgentWearLink Meta DAT Test Host")
                .accessibilityIdentifier("awl-meta-host-state")
        }
    }
}
