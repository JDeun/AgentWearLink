import AgentWearLinkOpenClaw
import XCTest

final class GatewayFailureTests: XCTestCase {
    func testNoRouteIsNetwork() {
        XCTAssertEqual(GatewayFailure.classify(URLError(.cannotFindHost), usedStoredGrant: true), .networkUnreachable)
        XCTAssertEqual(GatewayFailure.classify(URLError(.timedOut), usedStoredGrant: false), .networkUnreachable)
        XCTAssertEqual(GatewayFailure.classify(OpenClawHandshakeError.challengeTimeout, usedStoredGrant: true), .networkUnreachable)
    }

    func testPairingRequiredIsPending() {
        let pairing = OpenClawPairingRequired(
            requestID: nil, deviceID: nil, reason: nil, recommendedNextStep: nil,
            waitForResolution: true, pauseReconnect: false, retryable: true,
            retryAfterMilliseconds: nil
        )
        XCTAssertEqual(GatewayFailure.classify(OpenClawHandshakeError.pairingRequired(pairing), usedStoredGrant: false), .pairingPending)
    }

    func testRejectedStoredGrantMeansApproveAgain() {
        let error = AWLOpenClawError.gateway(code: "DEVICE_TOKEN_REJECTED", retryable: false)
        XCTAssertEqual(GatewayFailure.classify(error, usedStoredGrant: true), .pairingRevoked)
        XCTAssertEqual(GatewayFailure.classify(error, usedStoredGrant: false), .gatewayUnreachable)
        XCTAssertEqual(GatewayFailure.classify(AWLOpenClawError.gateway(code: "UNAVAILABLE", retryable: true), usedStoredGrant: true), .gatewayUnreachable)
    }

    func testApplyMarksTheRightHops() {
        var signals = ConnectionSignals()
        let now = Date()
        GatewayFailure.networkUnreachable.apply(to: &signals, at: now)
        XCTAssertEqual(signals.chain.firstProblem?.reason, .networkUnreachable)
        GatewayFailure.pairingRevoked.apply(to: &signals, at: now)
        XCTAssertEqual(signals.network, .reachable)
        XCTAssertEqual(signals.chain.firstProblem?.reason, .pairingRevoked)
    }
}
