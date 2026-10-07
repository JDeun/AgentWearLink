import CryptoKit
import Foundation
import XCTest
@testable import AgentWearLinkOpenClaw

final class OpenClawUpstreamContractTests: XCTestCase {
    func testCurrentUpstreamHelloDeviceTokenGrantWireShapeDecodes() throws {
        let sentinel = "UPSTREAM-HANDOFF-SECRET"
        let data = Data("""
        {
          "type":"hello-ok",
          "protocol":4,
          "server":{"version":"2026.10","connId":"contract"},
          "features":{"methods":["agent","agent.wait","chat.abort"],"events":["agent"]},
          "snapshot":{
            "presence":[],
            "health":{},
            "stateVersion":{"presence":1,"health":2},
            "uptimeMs":3
          },
          "auth":{
            "role":"bootstrap",
            "scopes":[],
            "deviceTokens":[{
              "deviceToken":"\(sentinel)",
              "role":"operator",
              "scopes":["operator.read"],
              "issuedAtMs":1737264000000
            }]
          },
          "policy":{
            "maxPayload":1048576,
            "maxBufferedBytes":2097152,
            "tickIntervalMs":15000,
            "attachments":{"maxBytes":524288,"maxImageBytes":524288}
          }
        }
        """.utf8)

        let hello = try JSONDecoder().decode(OpenClawHelloOK.self, from: data)
        let grant = try XCTUnwrap(hello.auth.deviceTokens?.first)

        XCTAssertEqual(grant.token, sentinel)
        XCTAssertEqual(grant.role, "operator")
        XCTAssertEqual(grant.scopes, ["operator.read"])
        XCTAssertEqual(grant.issuedAtMs, 1_737_264_000_000)
        XCTAssertFalse(String(describing: grant).contains(sentinel))
        XCTAssertFalse(String(reflecting: grant).contains(sentinel))
    }

    func testCurrentAgentWaitStatusesDecodeWithoutInventedRunId() throws {
        for status in ["ok", "timeout", "error", "pending"] {
            let result = try JSONDecoder().decode(
                OpenClawAgentWaitResult.self,
                from: Data(#"{"status":"\#(status)"}"#.utf8)
            )
            XCTAssertEqual(result.status, status)
        }
    }

    func testSupportedAgentAndAbortParamsStayInsideUpstreamSchemas() throws {
        let agent = OpenClawAgentParams(
            message: "contract probe",
            sessionKey: "agent:main:main",
            idempotencyKey: "contract-idempotency"
        )
        let agentObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(agent))
                as? [String: Any]
        )
        XCTAssertEqual(agentObject["message"] as? String, "contract probe")
        XCTAssertEqual(agentObject["sessionKey"] as? String, "agent:main:main")
        XCTAssertEqual(
            agentObject["idempotencyKey"] as? String,
            "contract-idempotency"
        )

        let abort = OpenClawChatAbortParams(
            sessionKey: "agent:main:main",
            runId: "run-contract",
            agentId: "main"
        )
        let abortObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(abort))
                as? [String: Any]
        )
        XCTAssertEqual(abortObject["sessionKey"] as? String, "agent:main:main")
        XCTAssertEqual(abortObject["runId"] as? String, "run-contract")
        XCTAssertEqual(abortObject["agentId"] as? String, "main")
    }

    func testV3ProofVerifiesAgainstIndependentlyReconstructedUpstreamTuple() throws {
        let identity = OpenClawDeviceIdentity.generate()
        let client = OpenClawGatewayClientIdentity(
            id: "gateway-client",
            mode: "backend",
            platform: " IOS ",
            deviceFamily: " IPhone "
        )
        let challenge = OpenClawConnectChallenge(
            nonce: "contract-nonce",
            ts: 1_737_264_000_000
        )
        let scopes = ["operator.read", "operator.write"]
        let proof = try OpenClawDeviceProofBuilder().makeProof(
            identity: identity,
            client: client,
            role: "operator",
            scopes: scopes,
            token: "contract-token",
            challenge: challenge
        )

        let expectedFields = [
            "v3",
            try identity.deviceID,
            "gateway-client",
            "backend",
            "operator",
            scopes.joined(separator: ","),
            String(challenge.ts),
            "contract-token",
            challenge.nonce,
            "ios",
            "iphone"
        ]
        let upstreamPayload = Data(
            expectedFields.joined(separator: "|").utf8
        )

        let signature = try XCTUnwrap(
            Data(base64URLEncoded: proof.signature)
        )
        let publicKey = try Curve25519.Signing.PublicKey(
            rawRepresentation: identity.publicKeyRaw
        )
        XCTAssertTrue(
            publicKey.isValidSignature(signature, for: upstreamPayload)
        )
    }

    func testConnectChallengeCurrentWireShapeDecodes() throws {
        let challenge = try JSONDecoder().decode(
            OpenClawConnectChallenge.self,
            from: Data(#"{"nonce":"contract-nonce","ts":1737264000000}"#.utf8)
        )
        XCTAssertEqual(challenge.nonce, "contract-nonce")
        XCTAssertEqual(challenge.ts, 1_737_264_000_000)
    }
}

private extension Data {
    init?(base64URLEncoded value: String) {
        var normalized = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        normalized += String(
            repeating: "=",
            count: (4 - normalized.count % 4) % 4
        )
        self.init(base64Encoded: normalized)
    }
}
