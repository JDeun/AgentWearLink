import AgentWearLinkCore
import XCTest
@testable import AgentWearLinkMetaDATIntegration

final class MetaDATVoiceOnlyDeviceAdapterTests: XCTestCase {
    func testVoiceOnlyCapabilityProjectionNeverAdvertisesMedia() {
        let all: CapabilitySet = [
            .cameraSnapshot, .speechInput, .voiceInvocation, .speakerOutput
        ]
        XCTAssertEqual(
            MetaDATVoiceOnlyDeviceAdapter.voiceOnlyCapabilities(all),
            .voiceInvocation
        )
        XCTAssertTrue(
            MetaDATVoiceOnlyDeviceAdapter.voiceOnlyCapabilities([.speechInput]).isEmpty
        )
    }

    func testMissingVendorReadinessCannotAdvertiseVoice() {
        // The pinned SDK traps when Wearables.shared is accessed before
        // Wearables.configure(). A package-hosted XCTest is not a configured
        // Meta app: validate the pure capability policy here and reserve
        // vendor instance lifecycle for the app-hosted MockDeviceKit UI test.
        XCTAssertTrue(
            MetaDATVoiceOnlyDeviceAdapter.voiceOnlyCapabilities([]).isEmpty
        )
        XCTAssertTrue(
            MetaDATVoiceOnlyDeviceAdapter.voiceOnlyCapabilities([.cameraSnapshot, .speechInput]).isEmpty
        )
    }
}
