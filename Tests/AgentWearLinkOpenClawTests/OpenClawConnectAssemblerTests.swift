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
}
