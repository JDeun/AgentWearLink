import AgentWearLinkCore
import XCTest
@testable import AgentWearLinkMetaDATIntegration

final class MetaDATLiveCapabilitiesTests: XCTestCase {
    func testReadyInputCapabilitiesDoNotAdvertiseHostOutput() {
        var capabilities = MetaDATLiveCapabilities()
        capabilities.sessionReady = true
        capabilities.speechReady = true
        capabilities.cameraReady = true
        capabilities.voiceInvocationReady = true

        let value = capabilities.value
        XCTAssertTrue(value.contains(.textInput))
        XCTAssertTrue(value.contains(.speechInput))
        XCTAssertTrue(value.contains(.cameraSnapshot))
        XCTAssertTrue(value.contains(.voiceInvocation))
        XCTAssertFalse(value.contains(.textOutput))
        XCTAssertFalse(value.contains(.speakerOutput))
    }

    func testUnavailableSessionAdvertisesNothing() {
        var capabilities = MetaDATLiveCapabilities()
        capabilities.speechReady = true
        capabilities.cameraReady = true
        capabilities.voiceInvocationReady = true

        XCTAssertTrue(capabilities.value.isEmpty)
    }
}
