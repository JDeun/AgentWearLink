import XCTest
@testable import AgentWearLinkCore

final class AgentStreamDecoderTests: XCTestCase {
    func testDecodesTextDelta() throws {
        let decoder = PlainTextSSEDecoder()
        let id = InteractionID()

        XCTAssertEqual(
            try decoder.decode(
                event: ServerSentEvent(event: "delta", data: "hello"),
                interactionID: id
            ),
            .textDelta(id, "hello")
        )
    }

    func testDecodesCompletionSentinel() throws {
        let decoder = PlainTextSSEDecoder()
        let id = InteractionID()

        XCTAssertEqual(
            try decoder.decode(
                event: ServerSentEvent(data: "[DONE]"),
                interactionID: id
            ),
            .completed(id)
        )
    }
}
