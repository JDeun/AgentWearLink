import CryptoKit
import Foundation
import XCTest
@testable import AgentWearLinkOpenClaw

final class OpenClawConnectAssemblerTests: XCTestCase {
    private let challenge = OpenClawConnectChallenge(nonce: "nonce", ts: 123)

    private func makeHello(
        token: String,
        role: String = "operator",
        scopes: [String] = ["operator.read"],
        connectionID: String = "cas-test"
    ) throws -> OpenClawHelloOK {
        let object: [String: Any] = [
            "type": "hello-ok",
            "protocol": 4,
            "server": [
                "version": "2026.10",
                "connId": connectionID,
            ],
            "features": [
                "methods": [],
                "events": [],
            ],
            "auth": [
                "role": role,
                "scopes": scopes,
                "deviceToken": token,
            ],
            "policy": [
                "maxPayload": 1024,
                "maxBufferedBytes": 2048,
                "tickIntervalMs": 15000,
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(OpenClawHelloOK.self, from: data)
    }

    private func assertProof(
        _ result: OpenClawAssembledConnect,
        signs token: String?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let proof = try XCTUnwrap(result.params.device, file: file, line: line)
        let payload = OpenClawDeviceProofBuilder().buildPayloadV3(
            deviceID: try result.identity.deviceID,
            clientID: result.params.client.id,
            clientMode: result.params.client.mode,
            role: result.params.role,
            scopes: result.params.scopes,
            token: token,
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

        let signature = try XCTUnwrap(
            Data(base64Encoded: encodedSignature),
            file: file,
            line: line
        )
        let publicKey = try Curve25519.Signing.PublicKey(
            rawRepresentation: result.identity.publicKeyRaw
        )
        XCTAssertTrue(
            publicKey.isValidSignature(signature, for: payload),
            file: file,
            line: line
        )
    }

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
        XCTAssertEqual(result.params.auth?.token, "shared")
        XCTAssertNil(result.params.auth?.deviceToken)
        XCTAssertNil(result.params.auth?.bootstrapToken)
        XCTAssertFalse(result.usedStoredCredential)
        XCTAssertFalse(result.usedBootstrapToken)
        XCTAssertEqual(
            result.params.scopes,
            ["operator.read", "operator.write"]
        )
        try assertProof(result, signs: "shared")
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
        XCTAssertNil(result.params.auth?.token)
        XCTAssertEqual(result.params.auth?.deviceToken, "stored")
        XCTAssertNil(result.params.auth?.bootstrapToken)
        XCTAssertTrue(result.usedStoredCredential)
        XCTAssertEqual(
            result.params.scopes,
            ["operator.read", "operator.write"]
        )
        XCTAssertFalse(result.usedBootstrapToken)
        try assertProof(result, signs: "stored")
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

        XCTAssertEqual(result.effectiveToken, "bootstrap")
        XCTAssertNil(result.params.auth?.token)
        XCTAssertNil(result.params.auth?.deviceToken)
        XCTAssertEqual(result.params.auth?.bootstrapToken, "bootstrap")
        XCTAssertTrue(result.usedBootstrapToken)
        try assertProof(result, signs: "bootstrap")
    }

    func testExplicitDeviceTokenUsesDeviceTokenFieldAndSignature() async throws {
        let assembler = OpenClawConnectAssembler(
            identityManager: .init(
                store: InMemoryOpenClawDeviceIdentityStore()
            ),
            credentialStore: InMemoryOpenClawDeviceCredentialStore()
        )

        let result = try await assembler.assemble(
            version: "0.1",
            scopes: ["operator.read"],
            credentials: .init(explicitDeviceToken: "device-explicit"),
            challenge: challenge
        )

        XCTAssertNil(result.params.auth?.token)
        XCTAssertEqual(result.params.auth?.deviceToken, "device-explicit")
        XCTAssertNil(result.params.auth?.bootstrapToken)
        XCTAssertEqual(result.effectiveToken, "device-explicit")
        XCTAssertFalse(result.usedStoredCredential)
        try assertProof(result, signs: "device-explicit")
    }

    func testPasswordOnlyDoesNotBecomeDeviceSignatureToken() async throws {
        let assembler = OpenClawConnectAssembler(
            identityManager: .init(
                store: InMemoryOpenClawDeviceIdentityStore()
            ),
            credentialStore: InMemoryOpenClawDeviceCredentialStore()
        )

        let result = try await assembler.assemble(
            version: "0.1",
            scopes: ["operator.read"],
            credentials: .init(
                password: "password-only",
                bootstrapToken: "must-not-be-used"
            ),
            challenge: challenge
        )

        XCTAssertNil(result.params.auth?.token)
        XCTAssertNil(result.params.auth?.deviceToken)
        XCTAssertEqual(result.params.auth?.password, "password-only")
        XCTAssertNil(result.params.auth?.bootstrapToken)
        XCTAssertNil(result.effectiveToken)
        XCTAssertFalse(result.usedBootstrapToken)
        try assertProof(result, signs: nil)
    }

    func testSharedTokenAndExplicitDeviceTokenKeepDistinctWireFields() async throws {
        let assembler = OpenClawConnectAssembler(
            identityManager: .init(
                store: InMemoryOpenClawDeviceIdentityStore()
            ),
            credentialStore: InMemoryOpenClawDeviceCredentialStore()
        )

        let result = try await assembler.assemble(
            version: "0.1",
            scopes: ["operator.read"],
            credentials: .init(
                token: "shared",
                explicitDeviceToken: "device-explicit",
                bootstrapToken: "must-not-be-used"
            ),
            challenge: challenge
        )

        XCTAssertEqual(result.params.auth?.token, "shared")
        XCTAssertEqual(result.params.auth?.deviceToken, "device-explicit")
        XCTAssertNil(result.params.auth?.bootstrapToken)
        XCTAssertEqual(result.effectiveToken, "shared")
        XCTAssertFalse(result.usedStoredCredential)
        XCTAssertFalse(result.usedBootstrapToken)
        try assertProof(result, signs: "shared")
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

    func testDifferentAuthenticatedRoleIsReusedOnFreshConnect() async throws {
        let identity = OpenClawDeviceIdentity.generate()
        let deviceID = try identity.deviceID
        let identityStore = InMemoryOpenClawDeviceIdentityStore(identity: identity)
        let credentialStore = InMemoryOpenClawDeviceCredentialStore()
        let assembler = OpenClawConnectAssembler(
            identityManager: .init(store: identityStore),
            credentialStore: credentialStore
        )

        let first = try await assembler.assemble(
            version: "0.1",
            scopes: ["operator.read", "operator.write"],
            credentials: .init(bootstrapToken: "bootstrap"),
            challenge: challenge
        )
        try await assembler.persistHello(
            makeHello(
                token: "approved-device-token",
                role: "viewer",
                scopes: ["operator.read"]
            ),
            assembled: first
        )

        let loadedCredential = try await credentialStore.load(
            deviceID: deviceID,
            role: "operator"
        )
        let stored = try XCTUnwrap(loadedCredential)
        XCTAssertEqual(stored.role, "viewer")
        XCTAssertEqual(stored.requestedRole, "operator")
        XCTAssertEqual(stored.storageRole, "operator")

        let reconnect = try await assembler.assemble(
            version: "0.1",
            scopes: ["operator.read", "operator.write", "operator.admin"],
            credentials: .init(bootstrapToken: "must-not-be-used"),
            challenge: .init(nonce: "fresh-nonce", ts: 456)
        )

        XCTAssertTrue(reconnect.usedStoredCredential)
        XCTAssertEqual(reconnect.effectiveToken, "approved-device-token")
        XCTAssertEqual(reconnect.params.scopes, ["operator.read"])
        XCTAssertNil(reconnect.params.auth?.bootstrapToken)
    }

    func testInvalidatingRejectedStoredCredentialRemovesGrantActuallyUsed() async throws {
        let identity = OpenClawDeviceIdentity.generate()
        let credentialStore = InMemoryOpenClawDeviceCredentialStore()
        let deviceID = try identity.deviceID
        try await credentialStore.save(
            .init(
                deviceID: deviceID,
                role: "operator",
                scopes: ["operator.read"],
                token: "stored"
            )
        )
        let assembler = OpenClawConnectAssembler(
            identityManager: .init(
                store: InMemoryOpenClawDeviceIdentityStore(identity: identity)
            ),
            credentialStore: credentialStore
        )

        let assembled = try await assembler.assemble(
            version: "0.1",
            scopes: ["operator.read"],
            credentials: .init(bootstrapToken: "bootstrap"),
            challenge: challenge
        )

        XCTAssertTrue(assembled.usedStoredCredential)
        try await assembler.invalidateStoredCredentialIfUsed(assembled)

        let remaining = try await credentialStore.load(
            deviceID: deviceID,
            role: "operator"
        )
        XCTAssertNil(remaining)
    }

    func testExplicitTokenEqualToStoredValueDoesNotInvalidateStoredGrant() async throws {
        let identity = OpenClawDeviceIdentity.generate()
        let credentialStore = InMemoryOpenClawDeviceCredentialStore()
        let deviceID = try identity.deviceID
        try await credentialStore.save(
            .init(
                deviceID: deviceID,
                role: "operator",
                scopes: ["operator.read"],
                token: "same-token"
            )
        )
        let assembler = OpenClawConnectAssembler(
            identityManager: .init(
                store: InMemoryOpenClawDeviceIdentityStore(identity: identity)
            ),
            credentialStore: credentialStore
        )

        let assembled = try await assembler.assemble(
            version: "0.1",
            scopes: ["operator.read", "operator.write"],
            credentials: .init(token: "same-token"),
            challenge: challenge
        )

        XCTAssertFalse(assembled.usedStoredCredential)
        try await assembler.invalidateStoredCredentialIfUsed(assembled)

        let remaining = try await credentialStore.load(
            deviceID: deviceID,
            role: "operator"
        )
        XCTAssertEqual(remaining?.token, "same-token")
    }


    func testStaleHelloPersistenceCannotOverwriteNewerCredential() async throws {
        let identity = OpenClawDeviceIdentity.generate()
        let deviceID = try identity.deviceID
        let store = InMemoryOpenClawDeviceCredentialStore()
        let original = OpenClawDeviceCredential(
            deviceID: deviceID,
            role: "operator",
            scopes: ["operator.read"],
            token: "original"
        )
        try await store.save(original)

        let assembler = OpenClawConnectAssembler(
            identityManager: .init(
                store: InMemoryOpenClawDeviceIdentityStore(identity: identity)
            ),
            credentialStore: store
        )
        let staleSnapshot = try await assembler.assemble(
            version: "0.1",
            scopes: ["operator.read"],
            credentials: .init(),
            challenge: challenge
        )

        let newer = OpenClawDeviceCredential(
            deviceID: deviceID,
            role: "operator",
            scopes: ["operator.read", "operator.write"],
            token: "newer"
        )
        try await store.save(newer)

        try await assembler.persistHello(
            makeHello(token: "stale-rotation"),
            assembled: staleSnapshot
        )

        let persisted = try await store.load(
            deviceID: deviceID,
            role: "operator"
        )
        XCTAssertEqual(persisted, newer)
    }

    func testFirstCredentialPersistenceIsInsertOnlyAcrossStaleSnapshots() async throws {
        let identity = OpenClawDeviceIdentity.generate()
        let deviceID = try identity.deviceID
        let store = InMemoryOpenClawDeviceCredentialStore()
        let assembler = OpenClawConnectAssembler(
            identityManager: .init(
                store: InMemoryOpenClawDeviceIdentityStore(identity: identity)
            ),
            credentialStore: store
        )

        let firstSnapshot = try await assembler.assemble(
            version: "0.1",
            scopes: ["operator.read"],
            credentials: .init(bootstrapToken: "bootstrap-a"),
            challenge: challenge
        )
        let secondSnapshot = try await assembler.assemble(
            version: "0.1",
            scopes: ["operator.read"],
            credentials: .init(bootstrapToken: "bootstrap-b"),
            challenge: .init(nonce: "second", ts: 456)
        )

        try await assembler.persistHello(
            makeHello(token: "first-winner", connectionID: "first"),
            assembled: firstSnapshot
        )
        try await assembler.persistHello(
            makeHello(token: "late-loser", connectionID: "second"),
            assembled: secondSnapshot
        )

        let loaded = try await store.load(
            deviceID: deviceID,
            role: "operator"
        )
        let persisted = try XCTUnwrap(loaded)
        XCTAssertEqual(persisted.token, "first-winner")
    }

    func testStaleCredentialInvalidationCannotDeleteRotatedGrant() async throws {
        let identity = OpenClawDeviceIdentity.generate()
        let deviceID = try identity.deviceID
        let store = InMemoryOpenClawDeviceCredentialStore()
        let original = OpenClawDeviceCredential(
            deviceID: deviceID,
            role: "operator",
            scopes: ["operator.read"],
            token: "original"
        )
        try await store.save(original)

        let assembler = OpenClawConnectAssembler(
            identityManager: .init(
                store: InMemoryOpenClawDeviceIdentityStore(identity: identity)
            ),
            credentialStore: store
        )
        let staleSnapshot = try await assembler.assemble(
            version: "0.1",
            scopes: ["operator.read"],
            credentials: .init(),
            challenge: challenge
        )
        XCTAssertTrue(staleSnapshot.usedStoredCredential)

        let newer = OpenClawDeviceCredential(
            deviceID: deviceID,
            role: "operator",
            scopes: ["operator.read"],
            token: "newer"
        )
        try await store.save(newer)

        try await assembler.invalidateStoredCredentialIfUsed(staleSnapshot)

        let persisted = try await store.load(
            deviceID: deviceID,
            role: "operator"
        )
        XCTAssertEqual(persisted, newer)
    }

    func testCredentialCASRejectsMismatchedExpectedValue() async throws {
        let store = InMemoryOpenClawDeviceCredentialStore()
        let current = OpenClawDeviceCredential(
            deviceID: "device",
            role: "operator",
            scopes: ["operator.read"],
            token: "current"
        )
        try await store.save(current)

        let staleExpected = OpenClawDeviceCredential(
            deviceID: "device",
            role: "operator",
            scopes: ["operator.read"],
            token: "stale"
        )
        let replacement = OpenClawDeviceCredential(
            deviceID: "device",
            role: "operator",
            scopes: ["operator.read", "operator.write"],
            token: "replacement"
        )

        let saved = try await store.compareAndSave(
            replacement,
            expected: staleExpected
        )

        XCTAssertFalse(saved)
        let persisted = try await store.load(
            deviceID: "device",
            role: "operator"
        )
        XCTAssertEqual(persisted, current)
    }


}
