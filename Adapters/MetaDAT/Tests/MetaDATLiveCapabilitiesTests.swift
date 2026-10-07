import AgentWearLinkCore
import XCTest
@testable import AgentWearLinkMetaDATIntegration

final class MetaDATLiveCapabilitiesTests: XCTestCase {
    func testReadyInputCapabilitiesDoNotAdvertiseHostOutputOrSyntheticTextInput() {
        var capabilities = MetaDATLiveCapabilities()
        capabilities.sessionReady = true
        capabilities.speechReady = true
        capabilities.cameraReady = true
        capabilities.voiceInvocationReady = true

        let value = capabilities.value
        XCTAssertFalse(value.contains(.textInput))
        XCTAssertTrue(value.contains(.speechInput))
        XCTAssertTrue(value.contains(.cameraSnapshot))
        XCTAssertTrue(value.contains(.voiceInvocation))
        XCTAssertFalse(value.contains(.textOutput))
        XCTAssertFalse(value.contains(.speakerOutput))
    }

    func testSessionOwnedCapabilitiesDisappearWhenSessionIsUnavailable() {
        var capabilities = MetaDATLiveCapabilities()
        capabilities.speechReady = true
        capabilities.cameraReady = true

        XCTAssertTrue(capabilities.value.isEmpty)

        capabilities.sessionReady = true
        XCTAssertTrue(capabilities.value.contains(.speechInput))
        XCTAssertTrue(capabilities.value.contains(.cameraSnapshot))

        capabilities.sessionReady = false
        XCTAssertTrue(capabilities.value.isEmpty)
    }

    func testVoiceInvocationAvailabilityIsIndependentFromDeviceSession() {
        var capabilities = MetaDATLiveCapabilities()
        capabilities.voiceInvocationReady = true

        let value = capabilities.value
        XCTAssertTrue(value.contains(.voiceInvocation))
        XCTAssertFalse(value.contains(.speechInput))
        XCTAssertFalse(value.contains(.cameraSnapshot))
    }

    func testCapabilitySourceUpdatesAndResetsAtomically() {
        let source = MetaDATLiveCapabilitySource()
        XCTAssertTrue(source.value.isEmpty)

        source.update(
            sessionReady: true,
            speechReady: true,
            cameraReady: true
        )

        let ready = source.value
        XCTAssertTrue(ready.contains(.speechInput))
        XCTAssertTrue(ready.contains(.cameraSnapshot))

        source.reset()
        XCTAssertTrue(source.value.isEmpty)
    }
}
