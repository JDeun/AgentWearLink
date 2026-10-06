import Foundation
import XCTest
@testable import AgentWearLinkOpenClaw

final class OpenClawAgentRunTests: XCTestCase {
    func testAgentEventDecodesAssistantStream() throws {
        let value: JSONValue = .object([
            "runId": .string("run-1"),
            "stream": .string("assistant"),
            "seq": .number(2),
            "data": .object(["delta": .string("안녕")])
        ])
        let data = try JSONEncoder().encode(value)
        let event = try JSONDecoder().decode(
            OpenClawAgentEvent.self,
            from: data
        )

        XCTAssertEqual(event.runId, "run-1")
        XCTAssertEqual(event.stream, "assistant")
        XCTAssertEqual(event.seq, 2)
        XCTAssertEqual(
            event.data,
            .object(["delta": .string("안녕")])
        )
    }

    func testWaitTimeoutRemainsNonTerminalRepresentation() throws {
        let data = Data(#"""
        {
          "runId":"run-1",
          "status":"timeout"
        }
        """#.utf8)

        let result = try JSONDecoder().decode(
            OpenClawAgentWaitResult.self,
            from: data
        )

        XCTAssertEqual(result.status, "timeout")
        XCTAssertNil(result.endedAt)
    }

    func testSessionAbortTargetsExactRunOnly() throws {
        let params = OpenClawSessionAbortParams(runId: "run-1")
        let data = try JSONEncoder().encode(params)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(json?["runId"] as? String, "run-1")
        XCTAssertNil(json?["key"])
        XCTAssertNil(json?["clearQueued"])
    }
}
