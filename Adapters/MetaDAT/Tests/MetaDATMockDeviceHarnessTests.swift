import XCTest
import MWDATMockDevice
@testable import AgentWearLinkMetaDATIntegration

final class MetaDATMockDeviceHarnessTests: XCTestCase {
    func testPinnedSDKAndMockDeviceModuleCompileTogether() {
        XCTAssertEqual(MetaDATIntegrationBuildMarker.pinnedSDKVersion, "1.0.0")
        // Importing MWDATMockDevice in this target is intentional: this is the
        // compile-time seam for the vendor mock layer. Behavioral pairing/camera
        // fixtures are added once the mock server/client lifecycle is hosted by
        // an iOS test application.
    }
}
