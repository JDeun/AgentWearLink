import XCTest
import AgentWearLinkCore
@testable import AgentWearLinkMetaDATIntegration

final class MetaDATSpeechFailurePolicyTests: XCTestCase {
    struct PrivateVendorError: LocalizedError {
        let errorDescription: String? =
            "DEVICE_PRIVATE_SERIAL=123 SECRET_MIC_TOKEN=abc"
    }

    func testSpeechFailureIsNonterminalAndSanitized() {
        let event = MetaDATSpeechFailurePolicy.event(for: PrivateVendorError())
        XCTAssertEqual(
            event,
            .failed(nil, .capabilityUnavailable(
                "Meta DAT Speech error (details redacted)"
            ))
        )
        XCTAssertNil(event.interactionID)
        XCTAssertFalse(String(reflecting: event).contains("DEVICE_PRIVATE_SERIAL"))
        XCTAssertFalse(String(reflecting: event).contains("SECRET_MIC_TOKEN"))
    }

    func testSessionOwnedCapabilityCanDegradeWithoutLosingCameraAndVoice() {
        var capabilities = MetaDATLiveCapabilities()
        capabilities.sessionReady = true
        capabilities.speechReady = true
        capabilities.cameraReady = true
        capabilities.voiceInvocationReady = true

        capabilities.speechReady = false
        let after = capabilities.value
        XCTAssertFalse(after.contains(.speechInput))
        XCTAssertTrue(after.contains(.cameraSnapshot))
        XCTAssertTrue(after.contains(.voiceInvocation))
    }
}
