import Foundation
import XCTest

private actor TerminalWaitScript {
    private var results: [OpenClawAgentWaitResult]
    private(set) var observedTimeouts: [Int] = []

    init(results: [OpenClawAgentWaitResult]) {
        self.results = results
    }

    func next(timeoutMilliseconds: Int) throws -> OpenClawAgentWaitResult {
        observedTimeouts.append(timeoutMilliseconds)
        guard !results.isEmpty else {
            throw OpenClawNativeAdapterError.terminalWaitLimitExceeded(
                maximumPolls: observedTimeouts.count
            )
        }
        return results.removeFirst()
    }

    func callCount() -> Int {
        observedTimeouts.count
    }
}

private func terminalWaitResult(_ status: String) throws -> OpenClawAgentWaitResult {
    try JSONDecoder().decode(
        OpenClawAgentWaitResult.self,
        from: Data(
            """
            {"runId":"run-1","status":"\(status)"}
            """.utf8
        )
    )
}

@testable import AgentWearLinkOpenClaw

final class OpenClawNativeAgentAdapterTests: XCTestCase {
    func testTerminalPollingReturnsAfterPendingTimeoutThenSuccess() async throws {
        let script = TerminalWaitScript(
            results: [
                try terminalWaitResult("pending"),
                try terminalWaitResult("timeout"),
                try terminalWaitResult("ok")
            ]
        )

        let result = try await OpenClawNativeAgentAdapter.pollUntilTerminal(
            maximumPolls: 4,
            pollTimeoutMilliseconds: 123
        ) { timeoutMilliseconds in
            try await script.next(timeoutMilliseconds: timeoutMilliseconds)
        }

        XCTAssertEqual(result.status, "ok")
        let callCount = await script.callCount()
        let timeouts = await script.observedTimeouts
        XCTAssertEqual(callCount, 3)
        XCTAssertEqual(timeouts, [123, 123, 123])
    }

    func testTerminalPollingFailsAtConfiguredNonTerminalLimit() async throws {
        let script = TerminalWaitScript(
            results: [
                try terminalWaitResult("pending"),
                try terminalWaitResult("timeout"),
                try terminalWaitResult("pending")
            ]
        )

        do {
            _ = try await OpenClawNativeAgentAdapter.pollUntilTerminal(
                maximumPolls: 3,
                pollTimeoutMilliseconds: 30_000
            ) { timeoutMilliseconds in
                try await script.next(timeoutMilliseconds: timeoutMilliseconds)
            }
            XCTFail("Expected terminal poll limit failure")
        } catch let error as OpenClawNativeAdapterError {
            XCTAssertEqual(
                error,
                .terminalWaitLimitExceeded(maximumPolls: 3)
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let callCount = await script.callCount()
        XCTAssertEqual(callCount, 3)
    }

    func testTerminalPollingReturnsErrorStatusWithoutExtraPoll() async throws {
        let script = TerminalWaitScript(
            results: [
                try terminalWaitResult("error"),
                try terminalWaitResult("pending")
            ]
        )

        let result = try await OpenClawNativeAgentAdapter.pollUntilTerminal(
            maximumPolls: 3,
            pollTimeoutMilliseconds: 30_000
        ) { timeoutMilliseconds in
            try await script.next(timeoutMilliseconds: timeoutMilliseconds)
        }

        XCTAssertEqual(result.status, "error")
        let callCount = await script.callCount()
        XCTAssertEqual(callCount, 1)
    }

    func testSubmissionIdentityIsStablePerLogicalSubmissionAndFreshForNextTurn() {
        let firstUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

        let first = OpenClawSubmissionIdentity(rawValue: firstUUID)
        let retryOfFirst = first
        let second = OpenClawSubmissionIdentity(rawValue: secondUUID)

        XCTAssertEqual(first.idempotencyKey, retryOfFirst.idempotencyKey)
        XCTAssertNotEqual(first.idempotencyKey, second.idempotencyKey)
        XCTAssertEqual(first.idempotencyKey, firstUUID.uuidString)
        XCTAssertEqual(second.idempotencyKey, secondUUID.uuidString)
    }

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
