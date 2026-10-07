import XCTest
@testable import AgentWearLinkMetaDATIntegration

final class MetaDATDeviceSelectionPolicyTests: XCTestCase {
    func testEqualRankSelectionIsStableAcrossRosterOrder() {
        let firstRoster = [
            MetaDATDeviceSelectionCandidate(identifier: "device-c", rank: 0),
            MetaDATDeviceSelectionCandidate(identifier: "device-a", rank: 0),
            MetaDATDeviceSelectionCandidate(identifier: "device-b", rank: 0)
        ]
        let secondRoster = [
            MetaDATDeviceSelectionCandidate(identifier: "device-b", rank: 0),
            MetaDATDeviceSelectionCandidate(identifier: "device-c", rank: 0),
            MetaDATDeviceSelectionCandidate(identifier: "device-a", rank: 0)
        ]

        XCTAssertEqual(
            MetaDATDeviceSelectionPolicy.selectedIdentifier(from: firstRoster),
            "device-a"
        )
        XCTAssertEqual(
            MetaDATDeviceSelectionPolicy.selectedIdentifier(from: secondRoster),
            "device-a"
        )
    }

    func testRankWinsBeforeIdentifierTieBreaker() {
        let candidates = [
            MetaDATDeviceSelectionCandidate(identifier: "device-a", rank: 2),
            MetaDATDeviceSelectionCandidate(identifier: "device-z", rank: 1)
        ]

        XCTAssertEqual(
            MetaDATDeviceSelectionPolicy.selectedIdentifier(from: candidates),
            "device-z"
        )
    }

    func testEmptyRosterHasNoSelection() {
        XCTAssertNil(
            MetaDATDeviceSelectionPolicy.selectedIdentifier(from: [])
        )
    }
}
