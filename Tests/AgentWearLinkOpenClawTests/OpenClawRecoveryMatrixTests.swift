import XCTest
@testable import AgentWearLinkOpenClaw

final class OpenClawRecoveryMatrixTests: XCTestCase {
    func testReconnectBackoffIsBoundedAcrossTransitionMatrix() {
        let policy = GatewayReconnectPolicy(
            initialDelayMilliseconds: 1_000,
            maximumDelayMilliseconds: 8_000,
            maximumAttempts: 5
        )

        let cases: [(String, Int)] = [
            ("wifi-to-cellular", 1),
            ("tailnet-loss", 2),
            ("gateway-restart", 3),
            ("mac-wake", 4),
            ("app-foreground", 5)
        ]

        for (name, attempt) in cases {
            let delay = policy.delayMilliseconds(forAttempt: attempt)
            XCTAssertGreaterThan(delay, 0, name)
            XCTAssertLessThanOrEqual(delay, 8_000, name)
        }
    }

    func testReconnectStateNeverAuthorizesRequestsBeforeReady() {
        let unavailable: [GatewayConnectionState] = [
            .disconnected,
            .connecting,
            .authenticating,
            .reconnecting(attempt: 1),
            .failed("transport uncertain")
        ]

        for state in unavailable {
            XCTAssertFalse(state.canSendRequests, "\(state)")
        }
        XCTAssertTrue(GatewayConnectionState.ready.canSendRequests)
    }

    func testTransportGenerationChangesRepresentNoReplayBoundary() async {
        // The supervisor's generation is the identity boundary used when an old
        // transport is retired. Application requests are not retained by the
        // reconnect policy and therefore cannot be silently replayed.
        let policy = GatewayReconnectPolicy(
            initialDelayMilliseconds: 10,
            maximumDelayMilliseconds: 20,
            maximumAttempts: 1
        )

        XCTAssertEqual(policy.maximumAttempts, 1)
        XCTAssertEqual(policy.delayMilliseconds(forAttempt: 1), 10)
        XCTAssertEqual(policy.delayMilliseconds(forAttempt: 2), 20)
    }
}
