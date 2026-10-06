import XCTest
@testable import AgentWearLinkOpenClaw

final class GatewayConnectionStateTests: XCTestCase {
    func testOnlyReadyCanSendRequests() {
        XCTAssertTrue(GatewayConnectionState.ready.canSendRequests)
        XCTAssertFalse(GatewayConnectionState.connecting.canSendRequests)
        XCTAssertFalse(GatewayConnectionState.authenticating.canSendRequests)
        XCTAssertFalse(
            GatewayConnectionState.reconnecting(attempt: 2).canSendRequests
        )
    }

    func testDefaultReconnectBackoffMatchesReferenceClient() {
        let policy = GatewayReconnectPolicy()

        XCTAssertEqual(policy.delayMilliseconds(forAttempt: 1), 1_000)
        XCTAssertEqual(policy.delayMilliseconds(forAttempt: 2), 2_000)
        XCTAssertEqual(policy.delayMilliseconds(forAttempt: 3), 4_000)
        XCTAssertEqual(policy.delayMilliseconds(forAttempt: 10), 30_000)
    }

    func testReconnectBackoffIsBounded() {
        let policy = GatewayReconnectPolicy(
            initialDelayMilliseconds: 500,
            maximumDelayMilliseconds: 4_000
        )

        XCTAssertEqual(policy.delayMilliseconds(forAttempt: 1), 500)
        XCTAssertEqual(policy.delayMilliseconds(forAttempt: 2), 1_000)
        XCTAssertEqual(policy.delayMilliseconds(forAttempt: 3), 2_000)
        XCTAssertEqual(policy.delayMilliseconds(forAttempt: 4), 4_000)
        XCTAssertEqual(policy.delayMilliseconds(forAttempt: 20), 4_000)
    }
}
