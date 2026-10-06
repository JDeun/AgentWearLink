import Foundation
import AgentWearLinkMetaDATIntegration

/// Minimal DEBUG iOS host entry point for Meta DAT behavioral integration.
///
/// The UI-test runner launches this executable with --awl-meta-ui-testing and
/// MWDAT_TEST_SERVER_PORT_FILE. Production applications should invoke the same
/// bootstrap from their normal app lifecycle rather than depending on this host.
@main
struct AgentWearLinkMetaDATTestHost {
    static func main() async {
        do {
            try await MetaDATMockHostBootstrap.configureIfRequested()
            // Keep the host alive while the external MockDeviceTestClient drives
            // the deterministic wearable lifecycle.
            RunLoop.main.run()
        } catch {
            fputs("Meta DAT test host bootstrap failed\n", stderr)
            exit(EXIT_FAILURE)
        }
    }
}
