import Foundation
import XCTest
@testable import LabTransport

final class LabInvitationTests: XCTestCase {
    func testFreshNamespaceRoundTripAndExactMarker() throws {
        let id = LabInvitation.newServiceID()
        XCTAssertTrue(id.uuidString.hasPrefix(LabInvitation.servicePrefix))
        XCTAssertNotEqual(id, LabInvitation.newServiceID())
        for size in LabSize.allCases {
            let invite = try XCTUnwrap(LabInvitation(serviceID: id, psm: 130, size: size))
            XCTAssertEqual(LabInvitation(invite.localText), invite)
            XCTAssertEqual(LabInvitation("  " + invite.localText + "\n"), invite)
            XCTAssertTrue(invite.matchesMarker(invite.marker))
            XCTAssertFalse(invite.matchesMarker(nil))
            let wrongPSM = try XCTUnwrap(LabInvitation(serviceID: id, psm: 131, size: size))
            XCTAssertFalse(invite.matchesMarker(wrongPSM.marker))
            XCTAssertFalse(invite.matchesMarker(invite.marker + Data([0])))
        }
    }

    func testRejectArbitraryServiceAndInvalidInvitation() {
        let id = LabInvitation.newServiceID().uuidString
        for text in [
            "", "AWL-LAB1|0000180F-0000-1000-8000-00805F9B34FB|130|64",
            "AWL-LAB1|\(id)|0|64", "AWL-LAB1|\(id)|65536|64",
            "AWL-LAB1|\(id)|127|64", "AWL-LAB1|\(id)|256|64",
            "AWL-LAB1|\(id)|130|65", "AWL-LAB1|\(id)|130|64|extra",
            "AWL-LAB1|\(id)|-1|64", String(repeating: "a", count: 101)
        ] { XCTAssertNil(LabInvitation(text)) }
    }
}
