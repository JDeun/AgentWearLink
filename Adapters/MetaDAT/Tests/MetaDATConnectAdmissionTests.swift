import XCTest
@testable import AgentWearLinkMetaDATIntegration

final class MetaDATConnectAdmissionTests: XCTestCase {
    func testConcurrentSessionStartFailsInsteadOfClaimingSuccess() {
        XCTAssertThrowsError(
            try MetaDATConnectAdmission.shouldStart(
                connecting: true,
                sessionActive: false
            )
        )
        // Session ownership can be installed before the asynchronous vendor
        // start reaches .started; that intermediate state is still pending.
        XCTAssertThrowsError(
            try MetaDATConnectAdmission.shouldStart(
                connecting: true,
                sessionActive: true
            )
        )
    }

    func testIdleSessionCanStartAndReadySessionIsIdempotent() throws {
        XCTAssertTrue(
            try MetaDATConnectAdmission.shouldStart(
                connecting: false,
                sessionActive: false
            )
        )
        XCTAssertFalse(
            try MetaDATConnectAdmission.shouldStart(
                connecting: false,
                sessionActive: true
            )
        )
    }
}
