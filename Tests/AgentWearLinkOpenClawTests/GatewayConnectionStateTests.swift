import Foundation
import XCTest
@testable import AgentWearLinkOpenClaw

final class GatewayConnectionStateTests: XCTestCase {
    private func hello(policy: String) throws -> OpenClawHelloOK {
        let data = Data("""
        {
          "type":"hello-ok","protocol":4,
          "server":{"version":"x","connId":"c"},
          "features":{"methods":[],"events":[]},
          "auth":{"role":"operator","scopes":["operator.read"]},
          "policy":\(policy)
        }
        """.utf8)
        return try JSONDecoder().decode(OpenClawHelloOK.self, from: data)
    }

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
    func testZeroMaximumAttemptsExplicitlyDisablesReconnectAttempts() {
        let policy = GatewayReconnectPolicy(maximumAttempts: 0)
        XCTAssertEqual(policy.maximumAttempts, 0)
    }

    func testReconnectPolicyClampsExtremeDelayConfiguration() {
        let policy = GatewayReconnectPolicy(
            initialDelayMilliseconds: Int.max,
            maximumDelayMilliseconds: Int.max
        )

        XCTAssertEqual(
            policy.initialDelayMilliseconds,
            GatewayReconnectPolicy.maximumSupportedDelayMilliseconds
        )
        XCTAssertEqual(
            policy.maximumDelayMilliseconds,
            GatewayReconnectPolicy.maximumSupportedDelayMilliseconds
        )
        XCTAssertEqual(
            policy.delayMilliseconds(forAttempt: Int.max),
            GatewayReconnectPolicy.maximumSupportedDelayMilliseconds
        )
    }

    func testHelloValidationRejectsUnsafePolicyBoundaries() throws {
        let policies = [
            #"{"maxPayload":4096,"maxBufferedBytes":8192,"tickIntervalMs":0}"#,
            #"{"maxPayload":4096,"maxBufferedBytes":8192,"tickIntervalMs":-1}"#,
            "{\"maxPayload\":4096,\"maxBufferedBytes\":8192,\"tickIntervalMs\":\(Int.max)}",
            #"{"maxPayload":4096,"maxBufferedBytes":1024,"tickIntervalMs":15000}"#,
            #"{"maxPayload":4096,"maxBufferedBytes":8192,"tickIntervalMs":15000,"attachments":{"maxBytes":1000,"maxImageBytes":1001}}"#,
            #"{"maxPayload":4096,"maxBufferedBytes":8192,"tickIntervalMs":15000,"attachments":{"maxBytes":0,"maxImageBytes":0}}"#
        ]

        for policy in policies {
            XCTAssertThrowsError(
                try OpenClawGatewayState.validateHello(hello(policy: policy)),
                policy
            ) {
                XCTAssertEqual($0 as? AWLOpenClawError, .invalidPolicy, policy)
            }
        }
    }

    func testHelloValidationKeepsUpstreamPolicyLimitsIndependent() throws {
        let hello = try hello(
            policy: #"{"maxPayload":4096,"maxBufferedBytes":1024,"tickIntervalMs":15000,"attachments":{"maxBytes":1000,"maxImageBytes":1001}}"#
        )

        XCTAssertNoThrow(try OpenClawGatewayState.validateHello(hello))
    }

    func testHelloValidationAcceptsMaximumTickBoundary() throws {
        let hello = try hello(
            policy: "{\"maxPayload\":4096,\"maxBufferedBytes\":8192,\"tickIntervalMs\":\(OpenClawGatewayState.maximumTickIntervalMilliseconds)}"
        )
        XCTAssertNoThrow(try OpenClawGatewayState.validateHello(hello))
    }

    func testHelloValidationRejectsProtocolMismatchWithoutPublishingReady() async throws {
        let state = OpenClawGatewayState()
        let hello = try JSONDecoder().decode(
            OpenClawHelloOK.self,
            from: Data(#"""
            {
              "type":"hello-ok","protocol":999,
              "server":{"version":"x","connId":"c"},
              "features":{"methods":[],"events":[]},
              "auth":{"role":"operator","scopes":["operator.read"],"deviceToken":"must-not-be-trusted"},
              "policy":{"maxPayload":4096,"maxBufferedBytes":8192,"tickIntervalMs":15000}
            }
            """#.utf8)
        )

        XCTAssertThrowsError(try OpenClawGatewayState.validateHello(hello)) {
            XCTAssertEqual($0 as? AWLOpenClawError, .protocolMismatch)
        }
        let connectionState = await state.connectionState
        XCTAssertEqual(connectionState, .disconnected)
    }

}

