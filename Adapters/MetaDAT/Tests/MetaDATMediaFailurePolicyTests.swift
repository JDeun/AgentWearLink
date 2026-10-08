import AgentWearLinkCore
import XCTest
@testable import AgentWearLinkMetaDATIntegration

final class MetaDATMediaFailurePolicyTests: XCTestCase {
    func testStandaloneMediaLossRemainsTerminalWithoutVoiceOwnership() {
        XCTAssertEqual(
            MetaDATMediaFailurePolicy.event("media stopped", preserveIndependentVoice: false),
            .failed(nil, .device("media stopped"))
        )
    }

    func testOptionalMediaLossCannotTerminateIndependentVoiceRuntime() {
        XCTAssertEqual(
            MetaDATMediaFailurePolicy.event("media stopped", preserveIndependentVoice: true),
            .failed(nil, .capabilityUnavailable("media stopped"))
        )
    }
}
