import AgentWearLinkCore
import XCTest
@testable import AgentWearLinkMetaDATIntegration

final class MetaDATVoiceInvocationChannelPolicyTests: XCTestCase {
    func testRetryBudgetIsFiniteAndDeterministic() {
        let policy = MetaDATVoiceReopenPolicy(
            delays: [.milliseconds(50), .milliseconds(100)]
        )
        XCTAssertEqual(policy.delay(afterFailure: 0), .milliseconds(50))
        XCTAssertEqual(policy.delay(afterFailure: 1), .milliseconds(100))
        XCTAssertNil(policy.delay(afterFailure: 2))
    }

    func testDefaultPolicyRemainsFiniteButCoversSlowVoiceChannelAttach() {
        let policy = MetaDATVoiceReopenPolicy()
        XCTAssertEqual(policy.delays.count, 6)
        XCTAssertEqual(policy.delay(afterFailure: 0), .milliseconds(250))
        XCTAssertEqual(policy.delay(afterFailure: 5), .seconds(8))
        XCTAssertNil(policy.delay(afterFailure: 6))
    }

    func testVoiceCapabilityIsIndependentFromMediaSession() {
        var capabilities = MetaDATLiveCapabilities()
        capabilities.voiceInvocationReady = true
        XCTAssertTrue(capabilities.value.contains(.voiceInvocation))
        XCTAssertFalse(capabilities.value.contains(.speechInput))
        XCTAssertFalse(capabilities.value.contains(.cameraSnapshot))
        capabilities.sessionReady = true
        capabilities.cameraReady = true
        XCTAssertTrue(capabilities.value.contains(.voiceInvocation))
        capabilities.voiceInvocationReady = false
        XCTAssertFalse(capabilities.value.contains(.voiceInvocation))
        XCTAssertTrue(capabilities.value.contains(.cameraSnapshot))
    }
}
