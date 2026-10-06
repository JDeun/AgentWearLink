import CryptoKit
import Foundation
import XCTest
@testable import AgentWearLinkOpenClaw

final class OpenClawConnectAssemblerTests: XCTestCase {
    private let challenge = OpenClawConnectChallenge(nonce: "nonce", ts: 123)

    func testExplicitSharedTokenWinsOverStoredDeviceToken() async throws {
        let identity = OpenClawDeviceIdentity.generate()
        let identityStore = InMemoryOpenClawDeviceIdentityStore(identity: identity)
        let credentials = InMemoryOpenClawDeviceCredentialStore()
        try await credentials.save(
            .init(
                deviceID: try identity.deviceID,
                role: "operator",
                scopes: ["operator.read"],
                token: "stored"
            )
        )
        let assembler = OpenClawConnectAssembler(
            identityManager: .init(store: identityStore),
            credentialStore: credentials
        )

        let result = try await assembler.assemble(
            version: "0.1",
            scopes: ["operator.read", "operator.write"],
            credentials: .init(
                token: "shared",
                bootstrapToken: "bootstrap"
            ),
            challenge: challenge
        )

        XCTAssertEqual(result.effectiveToken, "shared")
        XCTAssertFalse(result.usedBootstrapToken)
        XCTAssertEqual(
            result.params.scopes,
            ["operator.read", "operator.write"]
        )
    }

    func testStoredTokenReusesApprovedScopes() async throws {
        let identity = OpenClawDeviceIdentity.generate()
        let identityStore = InMemoryOpenClawDeviceIdentityStore(identity: identity)
        let credentials = InMemoryOpenClawDeviceCredentialStore()
        try await credentials.save(
            .init(
                deviceID: try identity.deviceID,
                role: "operator",
                scopes: ["operator.read", "operator.write"],
                token: "stored"
            )
        )
        let assembler = OpenClawConnectAssembler(
            identityManager: .init(store: identityStore),
            credentialStore: credentials
        )

        let result = try await assembler.assemble(
            version: "0.1",
            scopes: ["operator.read"],
            credentials: .init(bootstrapToken: "bootstrap"),
            challenge: challenge
        )

        XCTAssertEqual(result.effectiveToken, "stored")
        XCTAssertEqual(
            result.params.scopes,
            ["operator.read", "operator.write"]
        )
        XCTAssertFalse(result.usedBootstrapToken)
    }

    func testBootstrapUsedOnlyWhenNoOtherTokenExists() async throws {
        let assembler = OpenClawConnectAssembler(
            identityManager: .init(
                store: InMemoryOpenClawDeviceIdentityStore()
            ),
            credentialStore: InMemoryOpenClawDeviceCredentialStore()
        )

        let result = try await assembler.assemble(
            version: "0.1",
            scopes: ["operator.read"],
            credentials: .init(bootstrapToken: "bootstrap"),
            challenge: challenge
        )

        XCTAssertNil(result.effectiveToken)
        XCTAssertTrue(result.usedBootstrapToken)
    }

    func testCanonicalClientIdentityMatchesSignedV3Tuple() async throws {
        let identity = OpenClawDeviceIdentity.generate()
        let assembler = OpenClawConnectAssembler(
            identityManager: .init(
                store: InMemoryOpenClawDeviceIdentityStore(identity: identity)
            ),
            credentialStore: InMemoryOpenClawDeviceCredentialStore()
        )

        let result = try await assembler.assemble(
            version: "0.1",
            scopes: ["operator.read"],
            credentials: .init(token: "shared"),
            challenge: challenge
        )

        XCTAssertEqual(result.params.client.id, "gateway-client")
        XCTAssertEqual(result.params.client.mode, "backend")
        XCTAssertEqual(result.params.client.platform, "ios")
        XCTAssertEqual(result.params.client.deviceFamily, "iphone")

        let proof = try XCTUnwrap(result.params.device)
        let payload = OpenClawDeviceProofBuilder().buildPayloadV3(
            deviceID: try identity.deviceID,
            clientID: result.params.client.id,
            clientMode: result.params.client.mode,
            role: result.params.role,
            scopes: result.params.scopes,
            token: result.effectiveToken,
            nonce: proof.nonce,
            signedAt: proof.signedAt,
            platform: result.params.client.platform,
            deviceFamily: result.params.client.deviceFamily
        )
        var encodedSignature = proof.signature
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encodedSignature += String(
            repeating: "=",
            count: (4 - encodedSignature.count % 4) % 4
        )

        let signature = try XCTUnwrap(Data(base64Encoded: encodedSignature))
        let publicKey = try Curve25519.Signing.PublicKey(
            rawRepresentation: identity.publicKeyRaw
        )
        XCTAssertTrue(publicKey.isValidSignature(signature, for: payload))
    }

    func testSensitiveCredentialDescriptionsAreRedacted() throws {
        let sentinel = "AWL-SENTINEL-SECRET"
        let credentials = OpenClawConnectCredentials(
            token: sentinel,
            password: sentinel,
            explicitDeviceToken: sentinel,
            bootstrapToken: sentinel
        )
        XCTAssertFalse(String(describing: credentials).contains(sentinel))
        XCTAssertFalse(String(reflecting: credentials).contains(sentinel))

        let credential = OpenClawDeviceCredential(
            deviceID: "device",
            role: "operator",
            scopes: ["operator.read"],
            token: sentinel
        )
        XCTAssertFalse(String(describing: credential).contains(sentinel))
        XCTAssertFalse(String(reflecting: credential).contains(sentinel))
        XCTAssertTrue(String(describing: credential).contains("<redacted>"))
    }
    func testPersistedHelloGrantIsReusedOnFreshConnect() async throws {
        let identity = OpenClawDeviceIdentity.generate()
        let identityStore = InMemoryOpenClawDeviceIdentityStore(identity: identity)
        let credentialStore = InMemoryOpenClawDeviceCredentialStore()
        let assembler = OpenClawConnectAssembler(identityManager: .init(store: identityStore), credentialStore: credentialStore)
        let first = try await assembler.assemble(version: "0.1", scopes: ["operator.read", "operator.write"], credentials: .init(bootstrapToken: "bootstrap"), challenge: challenge)
        let helloData = Data(#"""
        {"type":"hello-ok","protocol":4,"server":{"version":"2026.10","connId":"c1"},"features":{"methods":[],"events":[]},"auth":{"role":"operator","scopes":["operator.read"],"deviceToken":"approved-device-token"},"policy":{"maxPayload":1024,"maxBufferedBytes":2048,"tickIntervalMs":15000}}
        """#.utf8)
        let hello = try JSONDecoder().decode(OpenClawHelloOK.self, from: helloData)
        try await assembler.persistHello(hello, assembled: first)
        let reconnect = try await assembler.assemble(version: "0.1", scopes: ["operator.read", "operator.write", "operator.admin"], credentials: .init(bootstrapToken: "must-not-be-used"), challenge: .init(nonce: "fresh-nonce", ts: 456))
        XCTAssertEqual(reconnect.effectiveToken, "approved-device-token")
        XCTAssertEqual(reconnect.params.scopes, ["operator.read"])
        XCTAssertFalse(reconnect.usedBootstrapToken)
        XCTAssertEqual(reconnect.params.device?.nonce, "fresh-nonce")
    }


    func testInvalidationRemovesOnlyStoredCredentialActuallyUsed() async throws {
        let identity = OpenClawDeviceIdentity.generate()
        let identityStore = InMemoryOpenClawDeviceIdentityStore(identity: identity)
        let store = InMemoryOpenClawDeviceCredentialStore()
        let deviceID = try identity.deviceID
        try await store.save(.init(
            deviceID: deviceID,
            role: "operator",
            scopes: ["operator.read"],
            token: "stored"
        ))
        let assembler = OpenClawConnectAssembler(
            identityManager: .init(store: identityStore),
            credentialStore: store
        )

        let storedConnect = try await assembler.assemble(
            version: "0.1",
            scopes: ["operator.read"],
            credentials: .init(),
            challenge: challenge
        )
        try await assembler.invalidateStoredCredentialIfUsed(storedConnect)
        let removed = try await store.load(deviceID: deviceID, role: "operator")
        XCTAssertNil(removed)

        try await store.save(.init(
            deviceID: deviceID,
            role: "operator",
            scopes: ["operator.read"],
            token: "stored-again"
        ))
        let explicitConnect = try await assembler.assemble(
            version: "0.1",
            scopes: ["operator.read"],
            credentials: .init(token: "explicit"),
            challenge: challenge
        )
        try await assembler.invalidateStoredCredentialIfUsed(explicitConnect)
        let preserved = try await store.load(deviceID: deviceID, role: "operator")
        XCTAssertEqual(preserved?.token, "stored-again")
    }

}
