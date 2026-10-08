import XCTest
@testable import AgentWearLinkOpenClaw

final class OpenClawValidationProfileTests: XCTestCase {
    func testReadOnlyAndMutatingValidationProfilesRemainDistinct() {
        let readOnly = OpenClawValidationProfile.readOnly
        let mutating = OpenClawValidationProfile.mutating

        XCTAssertNotEqual(readOnly.keychainService, mutating.keychainService)
        XCTAssertEqual(readOnly.scopes, ["operator.read"])
        XCTAssertEqual(mutating.scopes, ["operator.read", "operator.write"])
        XCTAssertEqual(readOnly.clientIdentity, .probe)
        XCTAssertEqual(mutating.clientIdentity, .backend)
    }

    func testReadOnlyProfileCannotImplicitlyClaimWriteScope() {
        XCTAssertFalse(
            OpenClawValidationProfile.readOnly.scopes.contains("operator.write")
        )
        XCTAssertTrue(
            OpenClawValidationProfile.mutating.scopes.contains("operator.write")
        )
    }

    func testDisposableDevelopmentKeychainServicesRemainDistinct() throws {
        let env = [
            "AWL_ALLOW_DEV_GATEWAY_TEST": "1",
            "AWL_DEV_KEYCHAIN_NONCE": "0123456789abcdefabcd"
        ]
        let read = try OpenClawDevelopmentKeychainIsolation.service(
            for: .readOnly, environment: env, isLoopback: true
        )
        let write = try OpenClawDevelopmentKeychainIsolation.service(
            for: .mutating, environment: env, isLoopback: true
        )
        XCTAssertNotEqual(read, write)
        XCTAssertTrue(read.hasSuffix(".read"))
        XCTAssertTrue(write.hasSuffix(".write"))
        XCTAssertFalse(read.contains(OpenClawValidationProfile.readOnly.keychainService))
        XCTAssertFalse(write.contains(OpenClawValidationProfile.mutating.keychainService))
    }

    func testDevelopmentKeychainNonceCannotBeUsedOutsideExplicitLoopback() {
        let badProfiles = [
            ["AWL_DEV_KEYCHAIN_NONCE": "0123456789abcdefabcd"],
            ["AWL_DEV_KEYCHAIN_NONCE": "bad!", "AWL_ALLOW_DEV_GATEWAY_TEST": "1"],
        ]
        for env in badProfiles {
            XCTAssertThrowsError(
                try OpenClawDevelopmentKeychainIsolation.service(
                    for: .readOnly, environment: env, isLoopback: true
                )
            )
        }
        XCTAssertThrowsError(
            try OpenClawDevelopmentKeychainIsolation.service(
                for: .mutating,
                environment: [
                    "AWL_ALLOW_DEV_GATEWAY_TEST": "1",
                    "AWL_DEV_KEYCHAIN_NONCE": "0123456789abcdefabcd"
                ],
                isLoopback: false
            )
        )
        let normal = try? OpenClawDevelopmentKeychainIsolation.service(
            for: .readOnly, environment: [:], isLoopback: false
        )
        XCTAssertEqual(normal, OpenClawValidationProfile.readOnly.keychainService)
    }

    func testEphemeralNegativeStoreIsRestrictedToIsolatedReadOnlyProbe() {
        let valid = [
            "AWL_DEV_GATEWAY_EXPECT_PAIRING": "1",
            "AWL_ALLOW_DEV_GATEWAY_TEST": "1",
            "AWL_OPENCLAW_EXPOSURE": "loopback",
            "AWL_DEV_GATEWAY_HEALTH_ONLY": "1",
            "AWL_DEV_GATEWAY_PROVE_ABORT": "0",
            "AWL_DEV_GATEWAY_USE_BUILT_PROBE": "1",
            "AWL_DEV_KEYCHAIN_NONCE": "0123456789abcdefabcd",
            "OPENCLAW_STATE_DIR": "/tmp/awl-real-dev-gateway-example/state",
            "AWL_OPENCLAW_URL": "ws://127.0.0.1:19031"
        ]
        func permitted(
            _ env: [String: String], loopback: Bool = true,
            profile: OpenClawValidationProfile = .readOnly
        ) -> Bool {
            OpenClawDevelopmentNegativePairingPolicy.permitsEphemeralIdentity(
                environment: env, isLoopback: loopback, profile: profile
            )
        }
        XCTAssertTrue(permitted(valid))
        XCTAssertFalse(permitted(valid, loopback: false))
        XCTAssertFalse(permitted(valid, profile: .mutating))
        let unsafe: [(String, String)] = [
            ("AWL_OPENCLAW_EXPOSURE", "tailnet-direct"),
            ("AWL_DEV_GATEWAY_EXPECT_PAIRING", "0"),
            ("AWL_DEV_GATEWAY_HEALTH_ONLY", "0"),
            ("AWL_DEV_GATEWAY_PROVE_ABORT", "1"),
            ("AWL_DEV_GATEWAY_USE_BUILT_PROBE", "0"),
            ("AWL_OPENCLAW_BOOTSTRAP_TOKEN", "token"),
            ("AWL_DEV_KEYCHAIN_NONCE", "invalid"),
            ("AWL_OPENCLAW_URL", "wss://example.ts.net:443"),
            ("AWL_OPENCLAW_URL", "ws://127.0.0.1:19031/?token=secret"),
            ("OPENCLAW_STATE_DIR", "/Users/owner/.openclaw"),
        ]
        for (key, value) in unsafe {
            XCTAssertFalse(permitted(valid.merging([key: value]) { _, new in new }),
                           "Ephemeral identity must reject unsafe " + key)
        }
        XCTAssertFalse(permitted(valid.filter { $0.key != "AWL_ALLOW_DEV_GATEWAY_TEST" }))
        XCTAssertFalse(permitted(valid.filter { $0.key != "AWL_DEV_KEYCHAIN_NONCE" }))
    }

}
