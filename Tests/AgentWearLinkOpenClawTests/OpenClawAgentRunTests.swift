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

    func testAcceptedRunKeepsResolvedSessionContext() throws {
        let data = Data(#"""
        {
          "runId":"run-1",
          "acceptedAt":123,
          "status":"accepted",
          "sessionKey":"agent:main:main",
          "agentId":"main"
        }
        """#.utf8)

        let accepted = try JSONDecoder().decode(
            OpenClawAgentAccepted.self,
            from: data
        )

        XCTAssertEqual(accepted.runId, "run-1")
        XCTAssertEqual(accepted.sessionKey, "agent:main:main")
        XCTAssertEqual(accepted.agentId, "main")
    }

    func testChatAbortTargetsExactRunAndSession() throws {
        let params = OpenClawChatAbortParams(
            sessionKey: "agent:main:main",
            runId: "run-1",
            agentId: "main"
        )
        let data = try JSONEncoder().encode(params)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(json?["runId"] as? String, "run-1")
        XCTAssertEqual(json?["sessionKey"] as? String, "agent:main:main")
        XCTAssertEqual(json?["agentId"] as? String, "main")
        XCTAssertNil(json?["clearQueued"])
    }

    func testAbortConfirmationMayOmitRunIds() throws {
        let data = Data(#"""
        {"aborted":true}
        """#.utf8)

        let result = try JSONDecoder().decode(
            OpenClawChatAbortResult.self,
            from: data
        )

        XCTAssertTrue(result.aborted)
        XCTAssertNil(result.runIds)
    }
}
