import AgentWearLinkCore
import XCTest
@testable import AgentWearLinkMetaDATIntegration

final class MetaDATVoiceWakeDeviceAdapterTests: XCTestCase {
    func testAdvertisesSpeechOnlyAfterVendorReadyAndNeverCamera() {
        XCTAssertTrue(MetaDATVoiceWakeDeviceAdapter.exposedCapabilities([]).isEmpty)
        XCTAssertEqual(
            MetaDATVoiceWakeDeviceAdapter.exposedCapabilities([
                .cameraSnapshot, .speechInput, .voiceInvocation, .speakerOutput
            ]),
            [.speechInput, .voiceInvocation]
        )
        XCTAssertEqual(
            MetaDATVoiceWakeDeviceAdapter.exposedCapabilities([.cameraSnapshot]),
            []
        )
    }
}
