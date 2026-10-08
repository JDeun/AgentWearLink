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

}
