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

    func testReadOnlyGrantReconnectRejectsWriteAndMismatchedAuthorization() {
        let valid = OpenClawDeviceCredential(
            deviceID: "dev", role: "operator",
            scopes: ["operator.read"], token: "approved-grant"
        )
        XCTAssertTrue(OpenClawReadOnlyGrantAdmission.permits(valid))
        XCTAssertFalse(OpenClawReadOnlyGrantAdmission.permits(nil))
        let disallowed: [OpenClawDeviceCredential] = [
            .init(deviceID: "dev", role: "operator",
                  scopes: ["operator.read", "operator.write"], token: "device"),
            .init(deviceID: "dev", role: "operator",
                  scopes: ["operator.write"], token: "device"),
            .init(deviceID: "dev", role: "operator",
                  scopes: [], token: "device"),
            .init(deviceID: "dev", role: "viewer",
                  requestedRole: "operator",
                  scopes: ["operator.read"], token: "device"),
            .init(deviceID: "dev", role: "operator",
                  storageRoleOverride: "other",
                  scopes: ["operator.read"], token: "device"),
            .init(deviceID: "dev", role: "operator",
                  scopes: ["operator.read"], token: "  ")
        ]
        for grant in disallowed {
            XCTAssertFalse(OpenClawReadOnlyGrantAdmission.permits(grant))
        }
    }

    func testEphemeralPositiveHealthPolicyIsSeparateAndReadOnly() {
        let baseline = [
            "AWL_DEV_GATEWAY_EXPECT_HEALTH_OK": "1",
            "AWL_ALLOW_DEV_GATEWAY_TEST": "1",
            "AWL_OPENCLAW_EXPOSURE": "loopback",
            "AWL_DEV_GATEWAY_HEALTH_ONLY": "1",
            "AWL_DEV_GATEWAY_PROVE_ABORT": "0",
            "AWL_DEV_GATEWAY_USE_BUILT_PROBE": "1",
            "AWL_DEV_KEYCHAIN_NONCE": "0123456789abcdefabcd",
            "OPENCLAW_STATE_DIR": "/tmp/awl-real-dev-gateway-health/state",
            "AWL_OPENCLAW_URL": "ws://127.0.0.1:19031",
            "AWL_OPENCLAW_TOKEN": "synthetic-token"
        ]
        func permitted(_ env: [String: String]) -> Bool {
            OpenClawDevelopmentPositiveHealthPolicy.permitsEphemeralIdentity(
                environment: env, isLoopback: true, profile: .readOnly
            )
        }
        XCTAssertTrue(permitted(baseline))
        XCTAssertFalse(
            OpenClawDevelopmentNegativePairingPolicy.permitsEphemeralIdentity(
                environment: baseline, isLoopback: true, profile: .readOnly
            )
        )
        XCTAssertFalse(
            OpenClawDevelopmentPositiveHealthPolicy.permitsEphemeralIdentity(
                environment: baseline, isLoopback: false, profile: .readOnly
            )
        )
        XCTAssertFalse(
            OpenClawDevelopmentPositiveHealthPolicy.permitsEphemeralIdentity(
                environment: baseline, isLoopback: true, profile: .mutating
            )
        )
        for (key, value) in [
            ("AWL_DEV_GATEWAY_EXPECT_PAIRING", "1"),
            ("AWL_DEV_GATEWAY_EXPECT_HEALTH_OK", "0"),
            ("AWL_DEV_GATEWAY_RECONNECT_STORED_ONLY", "1"),
            ("AWL_OPENCLAW_EXPOSURE", "tailnet-direct"),
            ("AWL_DEV_GATEWAY_HEALTH_ONLY", "0"),
            ("AWL_DEV_GATEWAY_PROVE_ABORT", "1"),
            ("AWL_DEV_GATEWAY_USE_BUILT_PROBE", "0"),
            ("AWL_OPENCLAW_BOOTSTRAP_TOKEN", "forbidden"),
            ("AWL_DEV_KEYCHAIN_NONCE", "wrong"),
            ("AWL_OPENCLAW_URL", "ws://100.64.0.1:19031"),
            ("OPENCLAW_STATE_DIR", "/Users/owner/.openclaw"),
        ] {
            XCTAssertFalse(permitted(baseline.merging([key: value]) { _, new in new }),
                           "Positive health must reject unsafe " + key)
        }
        XCTAssertFalse(permitted(baseline.filter { $0.key != "AWL_ALLOW_DEV_GATEWAY_TEST" }))
    }

    func testDisposableGrantModeIsIsolatedToOwnedLoopbackAndStrictlyTokenlessSecondProcess() {
        let valid: [String: String] = [
            "AWL_DEV_GATEWAY_EXPECT_GRANT_RECONNECT": "1",
            "AWL_ALLOW_DEV_GATEWAY_TEST": "1",
            "AWL_OPENCLAW_EXPOSURE": "loopback",
            "AWL_DEV_GATEWAY_HEALTH_ONLY": "1",
            "AWL_DEV_GATEWAY_PROVE_ABORT": "0",
            "AWL_DEV_GATEWAY_USE_BUILT_PROBE": "1",
            "AWL_DEV_KEYCHAIN_NONCE": "0123456789abcdefabcd",
            "OPENCLAW_STATE_DIR": "/tmp/awl-real-dev-gateway-test/state",
            "AWL_DEV_GATEWAY_GRANT_STORE": "/tmp/awl-real-dev-gateway-test/grant-cache",
            "AWL_OPENCLAW_URL": "ws://127.0.0.1:19031",
            "AWL_OPENCLAW_TOKEN": "synthetic-local-only"
        ]
        func permitted(_ env: [String: String], loopback: Bool = true,
                       profile: OpenClawValidationProfile = .readOnly) -> Bool {
            OpenClawDevelopmentDisposableGrantPolicy.permits(
                environment: env, isLoopback: loopback, profile: profile
            )
        }
        XCTAssertTrue(permitted(valid))
        let second = valid.merging([
            "AWL_DEV_GATEWAY_RECONNECT_STORED_ONLY": "1"
        ]) { _, new in new }.filter { $0.key != "AWL_OPENCLAW_TOKEN" }
        XCTAssertTrue(permitted(second))
        XCTAssertFalse(permitted(valid.merging([
            "AWL_DEV_GATEWAY_RECONNECT_STORED_ONLY": "1"
        ]) { _, new in new }))
        XCTAssertFalse(permitted(valid.filter { $0.key != "AWL_OPENCLAW_TOKEN" }))
        XCTAssertFalse(permitted(valid, loopback: false))
        XCTAssertFalse(permitted(valid, profile: .mutating))
        for (key, value) in [
            ("AWL_DEV_GATEWAY_EXPECT_HEALTH_OK", "1"),
            ("AWL_DEV_GATEWAY_EXPECT_PAIRING", "1"),
            ("AWL_DEV_GATEWAY_GRANT_STORE", "/Users/owner/.openclaw"),
            ("AWL_DEV_GATEWAY_RECONNECT_STORED_ONLY", "0"),
            ("AWL_OPENCLAW_EXPOSURE", "tailnet-direct"),
            ("AWL_OPENCLAW_URL", "ws://100.100.100.100:19031"),
            ("AWL_DEV_GATEWAY_HEALTH_ONLY", "0"),
            ("AWL_DEV_GATEWAY_PROVE_ABORT", "1"),
            ("AWL_OPENCLAW_BOOTSTRAP_TOKEN", "bad"),
            ("AWL_DEV_KEYCHAIN_NONCE", "invalid")
        ] {
            XCTAssertFalse(permitted(valid.merging([key: value]) { _, new in new }),
                           "Disposable grant must reject unsafe " + key)
        }
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
