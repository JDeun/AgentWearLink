import Foundation
import XCTest
@testable import AgentWearLinkOpenClaw

final class OpenClawDeviceIdentityTests: XCTestCase {
    func testIdentityManagerReusesPersistedKey() async throws {
        let store = InMemoryOpenClawDeviceIdentityStore()
        let manager = OpenClawDeviceIdentityManager(store: store)

        let first = try await manager.loadOrCreate()
        let second = try await manager.loadOrCreate()

        XCTAssertEqual(first, second)
        XCTAssertEqual(try first.deviceID, try second.deviceID)
    }

    func testV3PayloadMatchesCanonicalFieldOrder() throws {
        let builder = OpenClawDeviceProofBuilder()
        let data = builder.buildPayloadV3(
            deviceID: "device",
            clientID: "gateway-client",
            clientMode: "backend",
            role: "operator",
            scopes: ["operator.write", "operator.read"],
            token: "token",
            nonce: "nonce",
            signedAt: 123,
            platform: "ios",
            deviceFamily: "iphone"
        )

        XCTAssertEqual(
            String(decoding: data, as: UTF8.self),
            "v3|device|gateway-client|backend|operator|operator.write,operator.read|123|token|nonce|ios|iphone"
        )
    }

    func testProofUsesChallengeTimestampAndNonce() throws {
        let identity = OpenClawDeviceIdentity.generate()
        let proof = try OpenClawDeviceProofBuilder().makeProof(
            identity: identity,
            scopes: ["operator.read"],
            token: "token",
            challenge: .init(nonce: "server-nonce", ts: 1234)
        )

        XCTAssertEqual(proof.signedAt, 1234)
        XCTAssertEqual(proof.nonce, "server-nonce")
        XCTAssertFalse(proof.signature.contains("+"))
        XCTAssertFalse(proof.signature.contains("/"))
        XCTAssertFalse(proof.signature.contains("="))
    }

    func testInvalidChallengeIsRejected() {
        let identity = OpenClawDeviceIdentity.generate()

        XCTAssertThrowsError(
            try OpenClawDeviceProofBuilder().makeProof(
                identity: identity,
                scopes: [],
                token: nil,
                challenge: .init(nonce: "", ts: -1)
            )
        )
    }

    func testCredentialIsKeyedByDeviceAndRole() async throws {
        let store = InMemoryOpenClawDeviceCredentialStore()
        let credential = OpenClawDeviceCredential(
            deviceID: "device",
            role: "operator",
            scopes: ["operator.read"],
            token: "secret"
        )

        try await store.save(credential)

        let operatorCredential = try await store.load(
            deviceID: "device",
            role: "operator"
        )
        let nodeCredential = try await store.load(
            deviceID: "device",
            role: "node"
        )

        XCTAssertEqual(operatorCredential, credential)
        XCTAssertNil(nodeCredential)
    }
}
