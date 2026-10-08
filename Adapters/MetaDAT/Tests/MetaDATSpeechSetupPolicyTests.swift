import AgentWearLinkCore
import Foundation
import XCTest
@testable import AgentWearLinkMetaDATIntegration

final class MetaDATSpeechSetupPolicyTests: XCTestCase {
    func testMissingMicrophonePermissionDoesNotDisableIndependentCamera() {
        XCTAssertTrue(MetaDATSpeechSetupPolicy.mayContinueWithoutSpeech(
            AWLError.capabilityUnavailable("Meta DAT microphone permission is not granted")
        ))
    }

    func testUnsupportedSpeechOnSelectedDeviceDoesNotFailSession() {
        XCTAssertTrue(MetaDATSpeechSetupPolicy.mayContinueWithoutSpeech(
            AWLError.capabilityUnavailable("Meta DAT Speech is unavailable")
        ))
    }

    func testSessionFailureAndCancellationRemainFatal() {
        XCTAssertFalse(MetaDATSpeechSetupPolicy.mayContinueWithoutSpeech(
            AWLError.device("Meta DAT session start failed")
        ))
        XCTAssertFalse(MetaDATSpeechSetupPolicy.mayContinueWithoutSpeech(
            CancellationError()
        ))
        XCTAssertFalse(MetaDATSpeechSetupPolicy.mayContinueWithoutSpeech(
            NSError(domain: "test", code: 1)
        ))
    }
}
