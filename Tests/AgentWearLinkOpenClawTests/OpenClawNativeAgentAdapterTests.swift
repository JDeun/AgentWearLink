import XCTest
@testable import AgentWearLinkOpenClaw

final class OpenClawNativeAgentAdapterTests: XCTestCase {
    func testWaitResultDecodesPendingMetadata() throws {
        let data = Data(#"""
        {
          "runId":"run-1",
          "status":"pending",
          "timeoutPhase":"queue",
          "providerStarted":false
        }
        """#.utf8)

        let result = try JSONDecoder().decode(
            OpenClawAgentWaitResult.self,
            from: data
        )

        XCTAssertEqual(result.status, "pending")
        XCTAssertEqual(result.timeoutPhase, "queue")
        XCTAssertEqual(result.providerStarted, false)
        XCTAssertNil(result.endedAt)
    }

    func testWaitResultDecodesTerminalReceipt() throws {
        let data = Data(#"""
        {
          "runId":"run-1",
          "status":"ok",
          "startedAt":1,
          "endedAt":2,
          "terminalReply":{"text":"done"},
          "terminalReceipt":{"sourceReplyDelivered":true}
        }
        """#.utf8)

        let result = try JSONDecoder().decode(
            OpenClawAgentWaitResult.self,
            from: data
        )

        XCTAssertEqual(result.status, "ok")
        XCTAssertEqual(
            result.terminalReply,
            .object(["text": .string("done")])
        )
        XCTAssertEqual(
            result.terminalReceipt,
            .object(["sourceReplyDelivered": .bool(true)])
        )
    }
    func testAssistantProjectionEmitsOnlyExplicitAppendDelta() {
        let payload = JSONValue.object([
            "text": .string("hello"),
            "delta": .string("lo"),
            "replace": .bool(false)
        ])

        XCTAssertEqual(
            OpenClawNativeAgentAdapter.extractTextDelta(payload),
            "lo"
        )
    }

    func testAssistantProjectionSuppressesReplacementSnapshot() {
        let payload = JSONValue.object([
            "text": .string("corrected full reply"),
            "delta": .string(""),
            "replace": .bool(true)
        ])

        XCTAssertNil(OpenClawNativeAgentAdapter.extractTextDelta(payload))
    }

    func testAssistantProjectionSuppressesReplacementEvenWithDelta() {
        let payload = JSONValue.object([
            "text": .string("corrected full reply"),
            "delta": .string("corrected"),
            "replace": .bool(true)
        ])

        XCTAssertNil(OpenClawNativeAgentAdapter.extractTextDelta(payload))
    }

    func testAssistantProjectionSuppressesSnapshotOnlyAndRepeatedSnapshots() {
        let snapshot = JSONValue.object([
            "text": .string("cumulative reply")
        ])

        XCTAssertNil(OpenClawNativeAgentAdapter.extractTextDelta(snapshot))
        XCTAssertNil(OpenClawNativeAgentAdapter.extractTextDelta(snapshot))
    }

    func testAssistantProjectionSuppressesEmptyDelta() {
        let payload = JSONValue.object([
            "text": .string("cumulative reply"),
            "delta": .string("")
        ])

        XCTAssertNil(OpenClawNativeAgentAdapter.extractTextDelta(payload))
    }

}
