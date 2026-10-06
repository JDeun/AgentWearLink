import Foundation
import XCTest
@testable import AgentWearLinkOpenClaw

final class OpenClawFrameRouterTests: XCTestCase {
    func testRoutesResponse() throws {
        let data = Data(#"{"type":"res","id":"1","ok":true,"payload":{"type":"hello-ok"}}"#.utf8)
        let frame = try OpenClawFrameRouter().decodePreAuth(data)

        guard case let .response(response) = frame else {
            return XCTFail("Expected response")
        }
        XCTAssertEqual(response.id, "1")
    }

    func testRoutesEvent() throws {
        let data = Data(#"{"type":"event","event":"connect.challenge","payload":{"nonce":"n","ts":1}}"#.utf8)
        let frame = try OpenClawFrameRouter().decodePreAuth(data)

        guard case let .event(event) = frame else {
            return XCTFail("Expected event")
        }
        XCTAssertEqual(event.event, "connect.challenge")
    }

    func testRejectsOversizedPreAuthFrameBeforeJSONParsing() {
        let data = Data(
            repeating: 65,
            count: OpenClawProtocol.preAuthMaximumBytes + 1
        )

        XCTAssertThrowsError(
            try OpenClawFrameRouter().decodePreAuth(data)
        )
    }

    func testAcceptsPostAuthFrameAtConfiguredLimit() throws {
        let data = Data(#"{"type":"event","event":"tick"}"#.utf8)
        XCTAssertNoThrow(
            try OpenClawFrameRouter().decode(data, maximumBytes: data.count)
        )
    }

    func testRejectsPostAuthFrameOverConfiguredLimitBeforeDecode() {
        let data = Data(#"{"type":"event","event":"tick"}"#.utf8)
        XCTAssertThrowsError(
            try OpenClawFrameRouter().decode(data, maximumBytes: data.count - 1)
        ) { error in
            XCTAssertEqual(
                error as? OpenClawFrameError,
                .oversizedInboundFrame(
                    actual: data.count,
                    maximum: data.count - 1
                )
            )
        }
    }

    func testLargeMalformedFrameIsRejectedBySizeFirst() {
        let data = Data(repeating: 0x7B, count: 1_024)
        XCTAssertThrowsError(
            try OpenClawFrameRouter().decode(data, maximumBytes: 512)
        ) { error in
            XCTAssertEqual(
                error as? OpenClawFrameError,
                .oversizedInboundFrame(actual: 1_024, maximum: 512)
            )
        }
    }

}
