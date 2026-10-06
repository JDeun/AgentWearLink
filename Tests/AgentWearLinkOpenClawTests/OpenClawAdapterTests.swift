import XCTest
import AgentWearLinkCore
@testable import AgentWearLinkOpenClaw

final class OpenClawAdapterTests: XCTestCase {
    func testRequestUsesStableConversationAndOperatorToken() throws {
        let config = OpenClawConfiguration(
            baseURL: URL(string: "https://gateway.example.test:18789")!,
            bearerToken: "secret",
            conversationID: "wearable-main",
            sessionKey: "awl:test",
            messageChannel: "agentwearlink"
        )
        let id = InteractionID()
        let request = try OpenClawRequestFactory.makeRequest(
            configuration: config,
            request: AgentRequest(interactionID: id, text: "hello")
        )

        XCTAssertEqual(
            request.url?.absoluteString,
            "https://gateway.example.test:18789/v1/chat/completions"
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer secret"
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "x-openclaw-session-key"),
            "awl:test"
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "x-openclaw-message-channel"),
            "agentwearlink"
        )

        let data = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(json["model"] as? String, "openclaw/default")
        XCTAssertEqual(json["user"] as? String, "agentwearlink:wearable-main")
        XCTAssertEqual(json["stream"] as? Bool, true)
    }

    func testSSEParserDecodesTextDelta() throws {
        let line = #"data: {"choices":[{"delta":{"content":"안녕하세요"},"finish_reason":null}]}"#

        XCTAssertEqual(
            try OpenClawSSEParser.parse(
                line: line,
                maximumEventBytes: 4096
            ),
            .delta("안녕하세요")
        )
    }

    func testSSEParserRecognizesDone() throws {
        XCTAssertEqual(
            try OpenClawSSEParser.parse(
                line: "data: [DONE]",
                maximumEventBytes: 4096
            ),
            .done
        )
    }

    func testSSEParserRejectsOversizedEvent() {
        let line = "data: " + String(repeating: "x", count: 100)

        XCTAssertThrowsError(
            try OpenClawSSEParser.parse(
                line: line,
                maximumEventBytes: 16
            )
        )
    }
}
