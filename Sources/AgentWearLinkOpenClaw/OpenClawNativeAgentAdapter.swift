import AgentWearLinkCore
import Foundation

/// Identifies one logical OpenClaw agent submission independently from Core's
/// longer-lived interaction correlation identity.
struct OpenClawSubmissionIdentity: Sendable, Equatable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    var idempotencyKey: String {
        rawValue.uuidString
    }
}

public actor OpenClawNativeAgentAdapter: AgentAdapter {
    public static let defaultMaximumTerminalWaitPolls = 10
    public static let defaultTerminalPollTimeoutMilliseconds = 30_000

    private let supervisor: OpenClawGatewaySupervisor
    private let dispatcher: OpenClawRPCDispatcher
    private let runClient: OpenClawAgentRunClient
    private struct RunContext: Sendable {
        let runID: String
        let sessionKey: String?
        let agentID: String?
    }

    private let sessionKey: String?
    private let maximumTerminalWaitPolls: Int
    private let terminalPollTimeoutMilliseconds: Int
    private let responseBufferLimit: Int
    private var runs: [InteractionID: RunContext] = [:]

    public init(
        supervisor: OpenClawGatewaySupervisor,
        dispatcher: OpenClawRPCDispatcher,
        runClient: OpenClawAgentRunClient,
        sessionKey: String? = nil,
        maximumTerminalWaitPolls: Int = OpenClawNativeAgentAdapter.defaultMaximumTerminalWaitPolls,
        terminalPollTimeoutMilliseconds: Int = OpenClawNativeAgentAdapter.defaultTerminalPollTimeoutMilliseconds,
        responseBufferLimit: Int = AgentResponse.defaultBufferLimit
    ) {
        precondition(maximumTerminalWaitPolls > 0)
        precondition(terminalPollTimeoutMilliseconds > 0)
        precondition(responseBufferLimit > 0)
        self.supervisor = supervisor
        self.dispatcher = dispatcher
        self.runClient = runClient
        self.sessionKey = sessionKey
        self.maximumTerminalWaitPolls = maximumTerminalWaitPolls
        self.terminalPollTimeoutMilliseconds = terminalPollTimeoutMilliseconds
        self.responseBufferLimit = responseBufferLimit
    }

    public func connect() async throws {
        try await supervisor.start()
    }

    public func disconnect() async {
        await supervisor.stop()
        runs.removeAll(keepingCapacity: false)
    }

    public func responses(
        for request: AgentRequest
    ) async -> AsyncThrowingStream<AgentResponse, Error> {
        let client = runClient
        let sessionKey = sessionKey
        let responseBufferLimit = responseBufferLimit

        // A Core InteractionID is a correlation identity and may produce a
        // later, distinct logical agent turn after a prior turn completes.
        // Capture a fresh submission identity once for this stream so any
        // reconciliation of this same submission keeps one idempotency key,
        // while a later responses(for:) call receives a different key.
        let submissionIdentity = OpenClawSubmissionIdentity()

        return AsyncThrowingStream(
            bufferingPolicy: .bufferingOldest(responseBufferLimit)
        ) { continuation in
            let task = Task {
                do {
                    let accepted = try await Self.performSubmission(
                        idempotencyKey: submissionIdentity.idempotencyKey
                    ) {
                        try await client.submit(
                            message: request.text,
                            sessionKey: sessionKey,
                            idempotencyKey: submissionIdentity.idempotencyKey
                        )
                    }
                    await self.remember(
                        RunContext(
                            runID: accepted.runId,
                            sessionKey: accepted.sessionKey ?? sessionKey,
                            agentID: accepted.agentId
                        ),
                        for: request.interactionID
                    )

                    let updates = await client.updates(runID: accepted.runId)
                    let streamTask = Task<String, Error> {
                        var streamedText = ""
                        for try await update in updates {
                            if case let .assistant(_, payload) = update,
                               let delta = Self.extractTextDelta(payload) {
                                try Self.yieldResponse(
                                    .textDelta(request.interactionID, delta),
                                    to: continuation
                                )
                                streamedText += delta
                            }
                        }
                        return streamedText
                    }

                    let (terminal, streamedText) = try await Self.withOwnedUpdateTask(
                        streamTask
                    ) {
                        let terminal = try await self.waitUntilTerminal(
                            client: client,
                            runID: accepted.runId
                        )
                        // Close the per-run dispatcher subscription only after the
                        // terminal snapshot is known, then drain everything already
                        // accepted ahead of that boundary.
                        await client.finishUpdates(runID: accepted.runId)
                        let streamedText = try await streamTask.value
                        return (terminal, streamedText)
                    }

                    switch terminal.status {
                    case "ok":
                        if let suffix = try Self.terminalReplySuffix(
                            streamedText: streamedText,
                            terminalReply: terminal.terminalReply
                        ) {
                            try Self.yieldResponse(
                                .textDelta(request.interactionID, suffix),
                                to: continuation
                            )
                        }
                        try Self.yieldResponse(
                            .completed(request.interactionID),
                            to: continuation
                        )
                        continuation.finish()
                    case "error":
                        let message = terminal.error
                            ?? terminal.stopReason
                            ?? "OpenClaw agent run failed"
                        try Self.yieldResponse(
                            .failed(request.interactionID, .agent(message)),
                            to: continuation
                        )
                        continuation.finish()
                    case "timeout":
                        throw Self.terminalRunTimeoutError(terminal)
                    default:
                        throw OpenClawNativeAdapterError.unexpectedWaitStatus(
                            terminal.status
                        )
                    }

                    _ = await self.forget(request.interactionID)
                } catch is CancellationError {
                    await self.cancel(interactionID: request.interactionID)
                    continuation.finish()
                } catch {
                    if let context = await self.forget(request.interactionID) {
                        await client.finishUpdates(runID: context.runID)
                    }
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func withOwnedUpdateTask<UpdateValue: Sendable, T>(
        _ updateTask: Task<UpdateValue, Error>,
        operation: () async throws -> T
    ) async rethrows -> T {
        defer { updateTask.cancel() }
        return try await operation()
    }

    static func performSubmission(
        idempotencyKey: String,
        operation: () async throws -> OpenClawAgentAccepted
    ) async throws -> OpenClawAgentAccepted {
        do {
            return try await operation()
        } catch let error as OpenClawTransportSendError
            where error == .deliveryUncertain {
            // The mutating frame crossed the local transport handoff, but no
            // accepted run identity was observed. Do not replay or invent a
            // run ID: surface the uncertainty together with the safe
            // correlation key for diagnostics/reconciliation.
            throw OpenClawNativeAdapterError.submissionExecutionUncertain(
                idempotencyKey: idempotencyKey
            )
        }
    }

    private nonisolated static func yieldResponse(
        _ response: AgentResponse,
        to continuation: AsyncThrowingStream<AgentResponse, Error>.Continuation
    ) throws {
        switch continuation.yield(response) {
        case .enqueued:
            return
        case .dropped:
            let error = AWLError.overloaded(
                "agent response stream buffer capacity exceeded"
            )
            continuation.finish(throwing: error)
            throw error
        case .terminated:
            throw CancellationError()
        @unknown default:
            throw CancellationError()
        }
    }

    public func cancel(interactionID: InteractionID) async {
        _ = await cancellationOutcome(interactionID: interactionID)
    }

    public func cancellationOutcome(
        interactionID: InteractionID
    ) async -> AgentCancellationOutcome {
        guard let context = runs.removeValue(forKey: interactionID) else {
            return .handled
        }

        let outcome = await Self.remoteCancellationOutcome(
            interactionID: interactionID,
            sessionKey: context.sessionKey
        ) { sessionKey in
            try await self.runClient.cancel(
                runID: context.runID,
                sessionKey: sessionKey,
                agentID: context.agentID
            )
        }

        // Local subscriber/run bookkeeping must not be retained even when the
        // remote abort cannot be addressed or confirmed.
        await runClient.finishUpdates(runID: context.runID)
        return outcome
    }

    static func remoteCancellationOutcome(
        interactionID: InteractionID,
        sessionKey: String?,
        abort: (String) async throws -> Void
    ) async -> AgentCancellationOutcome {
        guard let sessionKey, !sessionKey.isEmpty else {
            return .uncertain(
                .agent(
                    "OpenClaw remote cancellation uncertain for interaction " +
                    "\(interactionID.rawValue.uuidString): accepted run has no session key"
                )
            )
        }

        do {
            try await abort(sessionKey)
            return .handled
        } catch {
            return .uncertain(
                .agent(
                    "OpenClaw remote cancellation uncertain for interaction " +
                    "\(interactionID.rawValue.uuidString): chat.abort was not confirmed"
                )
            )
        }
    }

    private func remember(
        _ context: RunContext,
        for interactionID: InteractionID
    ) {
        runs[interactionID] = context
    }

    @discardableResult
    private func forget(_ interactionID: InteractionID) -> RunContext? {
        runs.removeValue(forKey: interactionID)
    }

    // Internal-only deterministic evidence for adapter lifecycle tests.
    // Keeping this out of the public API lets tests prove run retirement
    // without timing sleeps or exposing OpenClaw bookkeeping to Core.
    func activeRunCountForTesting() -> Int {
        runs.count
    }

    private func waitUntilTerminal(
        client: OpenClawAgentRunClient,
        runID: String
    ) async throws -> OpenClawAgentWaitResult {
        let maximumPolls = maximumTerminalWaitPolls
        let pollTimeoutMilliseconds = terminalPollTimeoutMilliseconds

        return try await Self.pollUntilTerminal(
            maximumPolls: maximumPolls,
            pollTimeoutMilliseconds: pollTimeoutMilliseconds
        ) { timeoutMilliseconds in
            try await client.wait(
                runID: runID,
                timeoutMilliseconds: timeoutMilliseconds
            )
        }
    }

    static func pollUntilTerminal(
        maximumPolls: Int,
        pollTimeoutMilliseconds: Int,
        wait: @escaping @Sendable (Int) async throws -> OpenClawAgentWaitResult
    ) async throws -> OpenClawAgentWaitResult {
        precondition(maximumPolls > 0)
        precondition(pollTimeoutMilliseconds > 0)

        for _ in 0..<maximumPolls {
            try Task.checkCancellation()
            let result = try await wait(pollTimeoutMilliseconds)

            switch result.status {
            case "pending":
                continue
            case "timeout":
                if Self.isTerminalRunTimeout(result) {
                    return result
                }
                continue
            default:
                return result
            }
        }

        throw OpenClawNativeAdapterError.terminalWaitLimitExceeded(
            maximumPolls: maximumPolls
        )
    }

    /// Distinguishes a run-owned terminal timeout from a wait-only deadline.
    ///
    /// Current OpenClaw returns only `status: "timeout"` for a bare
    /// `agent.wait` deadline. Gateway draining may add `timeoutPhase` without
    /// terminal metadata, so phase/provider fields alone are intentionally not
    /// sufficient. A completed terminal snapshot, explicit terminal liveness,
    /// terminal reply, or pending terminal error stops polling.
    nonisolated static func isTerminalRunTimeout(
        _ result: OpenClawAgentWaitResult
    ) -> Bool {
        guard result.status == "timeout" else { return false }

        if result.pendingError == true {
            return true
        }
        if result.endedAt != nil {
            return true
        }
        if result.livenessState == "terminal" {
            return true
        }
        if result.terminalReply != nil {
            return true
        }
        return false
    }

    nonisolated static func terminalRunTimeoutError(
        _ result: OpenClawAgentWaitResult
    ) -> OpenClawNativeAdapterError {
        .terminalRunTimedOut(
            timeoutPhase: result.timeoutPhase,
            providerStarted: result.providerStarted,
            gatewayMessage: result.error
        )
    }

    /// Returns only the authoritative suffix that was not already emitted.
    ///
    /// A terminal reply that exactly matches streamed text is a replay and emits
    /// nothing. A longer terminal reply repairs missing trailing deltas. A
    /// non-prefix correction cannot be represented by Core's append-only
    /// textDelta contract, so fail closed rather than duplicate/corrupt output.
    nonisolated static func terminalReplySuffix(
        streamedText: String,
        terminalReply: JSONValue?
    ) throws -> String? {
        guard let terminalText = terminalReplyText(terminalReply) else {
            return nil
        }
        guard terminalText.hasPrefix(streamedText) else {
            throw OpenClawNativeAdapterError.terminalReplyMismatch
        }

        let suffix = terminalText.dropFirst(streamedText.count)
        return suffix.isEmpty ? nil : String(suffix)
    }

    nonisolated static func terminalReplyText(
        _ terminalReply: JSONValue?
    ) -> String? {
        guard case let .object(object)? = terminalReply,
              case let .string(text)? = object["text"] else {
            return nil
        }
        return text
    }

    /// Projects only explicit append semantics into Core's textDelta event.
    ///
    /// OpenClaw may also send cumulative `text` snapshots and `replace:true`
    /// corrections. Core currently has no replacement/reset event, so treating
    /// either shape as an append would duplicate or corrupt visible/TTS output.
    /// Final snapshot reconciliation is owned separately by the terminal-reply
    /// path (#285).
    nonisolated static func extractTextDelta(
        _ payload: JSONValue?
    ) -> String? {
        guard case let .object(object)? = payload else { return nil }

        if case .bool(true)? = object["replace"] {
            return nil
        }

        guard case let .string(delta)? = object["delta"],
              !delta.isEmpty else {
            return nil
        }
        return delta
    }
}

public enum OpenClawNativeAdapterError: Error, Sendable, Equatable {
    case submissionExecutionUncertain(idempotencyKey: String)
    case unexpectedWaitStatus(String)
    case terminalWaitLimitExceeded(maximumPolls: Int)
    case terminalReplyMismatch
    case terminalRunTimedOut(
        timeoutPhase: String?,
        providerStarted: Bool?,
        gatewayMessage: String?
    )
}
