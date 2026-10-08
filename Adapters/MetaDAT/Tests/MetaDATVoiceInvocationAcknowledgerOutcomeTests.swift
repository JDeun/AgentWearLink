import AgentWearLinkCore
import XCTest
@testable import AgentWearLinkMetaDATIntegration

final class MetaDATVoiceInvocationAcknowledgerOutcomeTests: XCTestCase {
    func testAcceptedLaunchProducesOneScopedInvocation() {
        let id = InteractionID()
        let outcome = MetaDATVoiceInvocationAcknowledger.outcome(
            acknowledged: true,
            interactionID: id
        )
        XCTAssertEqual(outcome, .invocation(id, nil))
        XCTAssertEqual(outcome.interactionID, id)
    }

    func testRefusedAckCannotEmitGlobalDeviceFailure() {
        let id = InteractionID()
        let outcome = MetaDATVoiceInvocationAcknowledger.outcome(
            acknowledged: false,
            interactionID: id
        )
        XCTAssertEqual(
            outcome,
            .failed(id, .device("Meta voice invocation acknowledgement was not delivered"))
        )
        XCTAssertEqual(outcome.interactionID, id)
    }
}
