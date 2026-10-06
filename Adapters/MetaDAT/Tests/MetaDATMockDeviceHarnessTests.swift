import XCTest
import MWDATCore
import MWDATMockDevice
@testable import AgentWearLinkMetaDATIntegration

final class MetaDATMockDeviceHarnessTests: XCTestCase {
    func testPinnedSDKAndMockDeviceModuleCompileTogether() {
        XCTAssertEqual(MetaDATIntegrationBuildMarker.pinnedSDKVersion, "1.0.0")
    }

    func testBehavioralMockRequiresAppHostedKeychainContext() throws {
        throw XCTSkip(
            "MockDeviceKit behavioral pairing requires an app-hosted iOS test context; " +
            "the package xctest runner has no Meta linked-app Keychain entitlement. " +
            "Use MetaDATMockHostBootstrap + the forthcoming XCUITest client harness (#101)."
        )
    }
}
