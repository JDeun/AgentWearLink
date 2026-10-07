import AgentWearLinkCore
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
            {"status":"\(status)"}
            """.utf8
        )
    )
}

@testable import AgentWearLinkOpenClaw


private actor OwnedUpdateTaskProbe {
    private(set) var observedCancellation = false

    func waitForCancellation() async throws {
        do {
            try await Task.sleep(for: .seconds(3_600))
        } catch is CancellationError {
            observedCancellation = true
            throw CancellationError()
        }
    }
}

private enum OwnedUpdateTaskTestError: Error {
    case terminalWaitFailed
}

private actor RemoteCancellationProbe {
    private let disconnectOnAbort: Bool
    private(set) var sessionKeys: [String] = []

    init(disconnectOnAbort: Bool = false) {
        self.disconnectOnAbort = disconnectOnAbort
    }

    func abort(sessionKey: String) throws {
        sessionKeys.append(sessionKey)
        if disconnectOnAbort {
            throw AWLOpenClawError.disconnected
        }
    }
}

final class OpenClawNativeAgentAdapterTests: XCTestCase {
    func testRemoteCancellationWithoutSessionKeyIsExplicitlyUncertain() async {
        let id = InteractionID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000252")!
        )
        let probe = RemoteCancellationProbe()

        let outcome = await OpenClawNativeAgentAdapter.remoteCancellationOutcome(
            interactionID: id,
            sessionKey: nil
        ) { sessionKey in
            try await probe.abort(sessionKey: sessionKey)
        }

        XCTAssertEqual(
            outcome,
            .uncertain(
                .agent(
                    "OpenClaw remote cancellation uncertain for interaction " +
                    "00000000-0000-0000-0000-000000000252: accepted run has no session key"
                )
            )
        )
        let sessionKeys = await probe.sessionKeys
        XCTAssertTrue(sessionKeys.isEmpty)
    }

    func testRemoteCancellationWithSessionKeyIsHandledAfterConfirmedAbort() async {
        let id = InteractionID()
        let probe = RemoteCancellationProbe()

        let outcome = await OpenClawNativeAgentAdapter.remoteCancellationOutcome(
            interactionID: id,
            sessionKey: "session-key"
        ) { sessionKey in
            try await probe.abort(sessionKey: sessionKey)
        }

        XCTAssertEqual(outcome, .handled)
        let sessionKeys = await probe.sessionKeys
        XCTAssertEqual(sessionKeys, ["session-key"])
    }

    func testRemoteCancellationDisconnectDuringAbortIsExplicitlyUncertain() async {
        let id = InteractionID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000253")!
        )
        let probe = RemoteCancellationProbe(disconnectOnAbort: true)

        let outcome = await OpenClawNativeAgentAdapter.remoteCancellationOutcome(
            interactionID: id,
            sessionKey: "session-key"
        ) { sessionKey in
            try await probe.abort(sessionKey: sessionKey)
        }

        XCTAssertEqual(
            outcome,
            .uncertain(
                .agent(
                    "OpenClaw remote cancellation uncertain for interaction " +
                    "00000000-0000-0000-0000-000000000253: chat.abort was not confirmed"
                )
            )
        )
        let sessionKeys = await probe.sessionKeys
        XCTAssertEqual(sessionKeys, ["session-key"])
    }

    func testSubmissionDeliveryUncertainBecomesTypedExecutionUncertainty() async {
        let correlationKey = "submission-correlation"

        do {
            _ = try await OpenClawNativeAgentAdapter.performSubmission(
                idempotencyKey: correlationKey
            ) {
                throw OpenClawTransportSendError.deliveryUncertain
            }
            XCTFail("Expected uncertain submission execution")
        } catch let error as OpenClawNativeAdapterError {
            XCTAssertEqual(
                error,
                .submissionExecutionUncertain(
                    idempotencyKey: correlationKey
                )
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSubmissionDefinitelyNotSentErrorRemainsTransportError() async {
        do {
            _ = try await OpenClawNativeAgentAdapter.performSubmission(
                idempotencyKey: "not-sent"
            ) {
                throw OpenClawTransportSendError.staleGeneration
            }
            XCTFail("Expected stale-generation rejection")
        } catch let error as OpenClawTransportSendError {
            XCTAssertEqual(error, .staleGeneration)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSubmissionPreSendCancellationRemainsCancellation() async {
        do {
            _ = try await OpenClawNativeAgentAdapter.performSubmission(
                idempotencyKey: "cancelled-before-send"
            ) {
                throw CancellationError()
            }
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // A pre-send cancellation remains a definite non-execution path.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSubmissionAcceptanceWinsWithoutReclassification() async throws {
        let accepted = try JSONDecoder().decode(
            OpenClawAgentAccepted.self,
            from: Data(
                #"""
                {
                  "runId":"run-accepted",
                  "acceptedAt":123,
                  "status":"accepted",
                  "sessionKey":"session-accepted"
                }
                """#.utf8
            )
        )

        let result = try await OpenClawNativeAgentAdapter.performSubmission(
            idempotencyKey: "accepted"
        ) {
            accepted
        }

        XCTAssertEqual(result, accepted)
    }

    func testOwnedUpdateTaskIsCancelledWhenTerminalWaitFails() async throws {
        let probe = OwnedUpdateTaskProbe()
        let updateTask = Task<Void, Error> {
            try await probe.waitForCancellation()
        }

        do {
            try await OpenClawNativeAgentAdapter.withOwnedUpdateTask(
                updateTask
            ) { () async throws -> Void in
                throw OwnedUpdateTaskTestError.terminalWaitFailed
            }
            XCTFail("Expected terminal wait failure")
        } catch OwnedUpdateTaskTestError.terminalWaitFailed {
            // Expected. Scope exit must still cancel the update consumer.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        _ = await updateTask.result
        let observedCancellation = await probe.observedCancellation
        XCTAssertTrue(observedCancellation)
    }

    func testOwnedUpdateTaskCanDrainNormallyBeforeScopeExit() async throws {
        let updateTask = Task<Void, Error> {}
        let value: Int = try await OpenClawNativeAgentAdapter.withOwnedUpdateTask(
            updateTask
        ) {
            try await updateTask.value
            return 42
        }

        XCTAssertEqual(value, 42)
    }

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

    func testBareWaitTimeoutRemainsNonTerminal() async throws {
        let script = TerminalWaitScript(
            results: [
                try terminalWaitResult("timeout"),
                try terminalWaitResult("ok")
            ]
        )

        let result = try await OpenClawNativeAgentAdapter.pollUntilTerminal(
            maximumPolls: 3,
            pollTimeoutMilliseconds: 30_000
        ) { timeoutMilliseconds in
            try await script.next(timeoutMilliseconds: timeoutMilliseconds)
        }

        XCTAssertEqual(result.status, "ok")
        let callCount = await script.callCount()
        XCTAssertEqual(callCount, 2)
    }

    func testGatewayDrainingTimeoutRemainsNonTerminal() async throws {
        let draining = try JSONDecoder().decode(
            OpenClawAgentWaitResult.self,
            from: Data(#"""
            {
              "status":"timeout",
              "timeoutPhase":"gateway_draining"
            }
            """#.utf8)
        )
        let script = TerminalWaitScript(
            results: [draining, try terminalWaitResult("ok")]
        )

        let result = try await OpenClawNativeAgentAdapter.pollUntilTerminal(
            maximumPolls: 3,
            pollTimeoutMilliseconds: 30_000
        ) { timeoutMilliseconds in
            try await script.next(timeoutMilliseconds: timeoutMilliseconds)
        }

        XCTAssertEqual(result.status, "ok")
        let callCount = await script.callCount()
        XCTAssertEqual(callCount, 2)
    }

    func testTerminalRunTimeoutStopsPollingAndPreservesMetadata() async throws {
        let terminalTimeout = try JSONDecoder().decode(
            OpenClawAgentWaitResult.self,
            from: Data(#"""
            {
              "status":"timeout",
              "startedAt":100,
              "endedAt":200,
              "livenessState":"terminal",
              "timeoutPhase":"runtime",
              "providerStarted":true,
              "error":"agent run timed out"
            }
            """#.utf8)
        )
        let script = TerminalWaitScript(
            results: [terminalTimeout, try terminalWaitResult("ok")]
        )

        let result = try await OpenClawNativeAgentAdapter.pollUntilTerminal(
            maximumPolls: 3,
            pollTimeoutMilliseconds: 30_000
        ) { timeoutMilliseconds in
            try await script.next(timeoutMilliseconds: timeoutMilliseconds)
        }

        XCTAssertEqual(result.status, "timeout")
        let callCount = await script.callCount()
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(
            OpenClawNativeAgentAdapter.terminalRunTimeoutError(result),
            .terminalRunTimedOut(
                timeoutPhase: "runtime",
                providerStarted: true,
                gatewayMessage: "agent run timed out"
            )
        )
    }

    func testPendingErrorTimeoutStopsPollingWithoutEndedAt() async throws {
        let terminalTimeout = try JSONDecoder().decode(
            OpenClawAgentWaitResult.self,
            from: Data(#"""
            {
              "status":"timeout",
              "pendingError":true,
              "error":"provider failed before wait completed"
            }
            """#.utf8)
        )
        let script = TerminalWaitScript(
            results: [terminalTimeout, try terminalWaitResult("ok")]
        )

        let result = try await OpenClawNativeAgentAdapter.pollUntilTerminal(
            maximumPolls: 3,
            pollTimeoutMilliseconds: 30_000
        ) { timeoutMilliseconds in
            try await script.next(timeoutMilliseconds: timeoutMilliseconds)
        }

        XCTAssertEqual(result.status, "timeout")
        let callCount = await script.callCount()
        XCTAssertEqual(callCount, 1)
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
          "status":"pending",
          "retryableTransportError":true,
          "livenessState":"waiting",
          "yielded":false,
          "pendingError":false,
          "timeoutPhase":"queue",
          "providerStarted":false
        }
        """#.utf8)

        let result = try JSONDecoder().decode(
            OpenClawAgentWaitResult.self,
            from: data
        )

        XCTAssertEqual(result.status, "pending")
        XCTAssertEqual(result.retryableTransportError, true)
        XCTAssertEqual(result.livenessState, "waiting")
        XCTAssertEqual(result.yielded, false)
        XCTAssertEqual(result.pendingError, false)
        XCTAssertEqual(result.timeoutPhase, "queue")
        XCTAssertEqual(result.providerStarted, false)
        XCTAssertNil(result.endedAt)
    }

    func testWaitResultDecodesCurrentTerminalReplyShape() throws {
        let data = Data(#"""
        {
          "status":"ok",
          "startedAt":1,
          "endedAt":2,
          "stopReason":"end_turn",
          "livenessState":"terminal",
          "yielded":true,
          "pendingError":false,
          "providerStarted":true,
          "terminalReply":{"text":"done"},
          "sourceReplyDelivered":true
        }
        """#.utf8)

        let result = try JSONDecoder().decode(
            OpenClawAgentWaitResult.self,
            from: data
        )

        XCTAssertEqual(result.status, "ok")
        XCTAssertEqual(result.stopReason, "end_turn")
        XCTAssertEqual(result.livenessState, "terminal")
        XCTAssertEqual(result.yielded, true)
        XCTAssertEqual(result.pendingError, false)
        XCTAssertEqual(result.providerStarted, true)
        XCTAssertEqual(
            result.terminalReply,
            .object(["text": .string("done")])
        )
        XCTAssertEqual(result.sourceReplyDelivered, true)
    }

    func testTerminalPollingAcceptsCurrentGatewayShapeWithoutRunID() async throws {
        let currentShape = try JSONDecoder().decode(
            OpenClawAgentWaitResult.self,
            from: Data(#"""
            {
              "status":"ok",
              "startedAt":100,
              "endedAt":200,
              "stopReason":"end_turn",
              "livenessState":"terminal",
              "yielded":true,
              "providerStarted":true,
              "terminalReply":{"text":"done"},
              "sourceReplyDelivered":true
            }
            """#.utf8)
        )
        let script = TerminalWaitScript(results: [currentShape])

        let result = try await OpenClawNativeAgentAdapter.pollUntilTerminal(
            maximumPolls: 2,
            pollTimeoutMilliseconds: 30_000
        ) { timeoutMilliseconds in
            try await script.next(timeoutMilliseconds: timeoutMilliseconds)
        }

        XCTAssertEqual(result.status, "ok")
        XCTAssertEqual(
            result.terminalReply,
            .object(["text": .string("done")])
        )
        let callCount = await script.callCount()
        XCTAssertEqual(callCount, 1)
    }
    func testTerminalReplyReconciliationEmitsOnlyMissingSuffix() throws {
        let suffix = try OpenClawNativeAgentAdapter.terminalReplySuffix(
            streamedText: "hello",
            terminalReply: .object(["text": .string("hello world")])
        )

        XCTAssertEqual(suffix, " world")
    }

    func testTerminalReplyReconciliationUsesFullReplyWhenNoDeltaArrived() throws {
        let suffix = try OpenClawNativeAgentAdapter.terminalReplySuffix(
            streamedText: "",
            terminalReply: .object(["text": .string("complete answer")])
        )

        XCTAssertEqual(suffix, "complete answer")
    }

    func testTerminalReplyReplayDoesNotDuplicateAlreadyStreamedText() throws {
        let suffix = try OpenClawNativeAgentAdapter.terminalReplySuffix(
            streamedText: "already complete",
            terminalReply: .object(["text": .string("already complete")])
        )

        XCTAssertNil(suffix)
    }

    func testTerminalReplyMismatchFailsClosedWithoutPrivateTextInError() throws {
        XCTAssertThrowsError(
            try OpenClawNativeAgentAdapter.terminalReplySuffix(
                streamedText: "old projection",
                terminalReply: .object(["text": .string("corrected projection")])
            )
        ) { error in
            XCTAssertEqual(
                error as? OpenClawNativeAdapterError,
                .terminalReplyMismatch
            )
            XCTAssertFalse(String(describing: error).contains("old projection"))
            XCTAssertFalse(String(describing: error).contains("corrected projection"))
        }
    }

    func testTerminalReplyWithoutTextNeedsNoReconciliation() throws {
        let suffix = try OpenClawNativeAgentAdapter.terminalReplySuffix(
            streamedText: "partial",
            terminalReply: .object(["kind": .string("metadata-only")])
        )

        XCTAssertNil(suffix)
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
