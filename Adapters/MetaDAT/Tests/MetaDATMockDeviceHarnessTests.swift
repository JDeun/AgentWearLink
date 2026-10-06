import XCTest
import MWDATCore
import MWDATMockDevice
@testable import AgentWearLinkMetaDATIntegration

@MainActor
final class MetaDATMockDeviceHarnessTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        try? Wearables.configure()
        MockDeviceKit.shared.enable()
    }

    override func tearDown() async throws {
        await MockDeviceKit.shared.disable()
        try await super.tearDown()
    }

    func testPinnedSDKAndMockDeviceModuleCompileTogether() {
        XCTAssertEqual(MetaDATIntegrationBuildMarker.pinnedSDKVersion, "1.0.0")
        // Importing MWDATMockDevice in this target is intentional: this is the
        // compile-time seam for the vendor mock layer. Behavioral pairing/camera
        // fixtures are added once the mock server/client lifecycle is hosted by
        // an iOS test application.
    }

    func testMockGlassesBecomeVisibleToWearables() async throws {
        let glasses = try MockDeviceKit.shared.pairGlasses(model: .rayBanMeta)
        glasses.powerOn()
        glasses.don()

        let deadline = ContinuousClock.now + .seconds(5)
        while Wearables.shared.devices.isEmpty && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }

        XCTAssertFalse(Wearables.shared.devices.isEmpty)
        XCTAssertNotNil(glasses.services.camera)
    }
}
