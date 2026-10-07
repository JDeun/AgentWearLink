import XCTest
@testable import AgentWearLinkMetaDATIntegration
import AgentWearLinkMetaDATTestSupport

final class MetaDATMockHostBootstrapTests: XCTestCase {
    func testNonTestLaunchIsNoOp() async throws {
        try await MetaDATMockHostBootstrap.configureIfRequested(
            arguments: ["AgentWearLinkHost"],
            environment: [:]
        )
    }

    func testContractUsesDedicatedLaunchArgumentAndPortEnvironment() {
        XCTAssertEqual(
            MetaDATMockHostBootstrap.launchArgument,
            "--awl-meta-ui-testing"
        )
        XCTAssertEqual(
            MetaDATMockHostBootstrap.portFileEnvironment,
            "MWDAT_TEST_SERVER_PORT_FILE"
        )
    }
}
