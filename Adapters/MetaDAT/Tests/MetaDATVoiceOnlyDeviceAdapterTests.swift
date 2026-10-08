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

    func testUnregisteredDefaultAdapterDoesNotAdvertiseVoiceReady() async {
        let adapter = MetaDATVoiceOnlyDeviceAdapter(vendor: MetaDATDeviceAdapter())
        XCTAssertTrue(adapter.capabilities.isEmpty)
        // Construction/inspection never starts DeviceSession or the microphone.
    }
}
