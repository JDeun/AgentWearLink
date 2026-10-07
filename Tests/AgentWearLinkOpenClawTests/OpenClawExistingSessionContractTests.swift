import XCTest
@testable import AgentWearLinkOpenClaw

/// Wire-format fixtures only; live adapter behavior is covered separately.
final class OpenClawExistingSessionWireContractTests: XCTestCase {
    func testAcceptedRunPreservesExistingSessionIdentity() throws {
        let data = Data(#"""
        {
          "runId":"run-existing-session",
          "sessionKey":"agent:main:main",
          "agentId":"main",
          "acceptedAt":1737264000000
        }
        """#.utf8)

        let accepted = try JSONDecoder().decode(
            OpenClawAgentAccepted.self,
            from: data
        )

        XCTAssertEqual(accepted.runId, "run-existing-session")
        XCTAssertEqual(accepted.sessionKey, "agent:main:main")
        XCTAssertEqual(accepted.agentId, "main")
    }

    func testAgentEventCarriesIncrementalAssistantDeltaForSameRun() throws {
        let data = Data(#"""
        {
          "runId":"run-existing-session",
          "stream":"assistant",
          "data":{"delta":"partial"}
        }
        """#.utf8)

        let event = try JSONDecoder().decode(OpenClawAgentEvent.self, from: data)

        XCTAssertEqual(event.runId, "run-existing-session")
        XCTAssertEqual(event.stream, "assistant")
        XCTAssertEqual(event.data, .object(["delta": .string("partial")]))
    }

    func testTerminalWaitCanCompleteAfterIncrementalAssistantEvent() throws {
        let data = Data(#"""
        {
          "status":"ok",
          "terminalReply":{"text":"partial complete"},
          "sourceReplyDelivered":true
        }
        """#.utf8)

        let terminal = try JSONDecoder().decode(
            OpenClawAgentWaitResult.self,
            from: data
        )

        XCTAssertEqual(terminal.status, "ok")
        XCTAssertEqual(terminal.sourceReplyDelivered, true)
        XCTAssertEqual(
            terminal.terminalReply,
            .object(["text": .string("partial complete")])
        )
    }
}
