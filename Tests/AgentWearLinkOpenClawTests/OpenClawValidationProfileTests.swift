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
}
