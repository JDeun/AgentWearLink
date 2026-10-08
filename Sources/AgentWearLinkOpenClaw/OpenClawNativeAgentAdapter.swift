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

private actor OpenClawEmittedTextAccumulator {
    private var text = ""

    func append(_ delta: String) {
        text += delta
    }

    func snapshot() -> String { text }
}

public actor OpenClawNativeAgentAdapter: AgentAdapter, VisionAgentAdapter {
    public static let defaultMaximumTerminalWaitPolls = 10
    public static let defaultTerminalPollTimeoutMilliseconds = 30_000
    public static let defaultMaximumAcceptedRunRecoveries = 2

    /// Explicit host/runtime capability decision. This defaults to false so the
    /// presence of the wire attachment schema alone never advertises vision.
    /// Hosts should enable it only after validating the selected OpenClaw
    /// runtime/model can consume image input. Negotiated attachment limits are
    /// still revalidated for every submission and after reconnect.
    public nonisolated let supportsVisionInput: Bool

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
    private let maximumAcceptedRunRecoveries: Int
    private let responseBufferLimit: Int
    private var runs: [InteractionID: RunContext] = [:]

    public init(
        supervisor: OpenClawGatewaySupervisor,
        dispatcher: OpenClawRPCDispatcher,
        runClient: OpenClawAgentRunClient,
        sessionKey: String? = nil,
        maximumTerminalWaitPolls: Int = OpenClawNativeAgentAdapter.defaultMaximumTerminalWaitPolls,
        terminalPollTimeoutMilliseconds: Int = OpenClawNativeAgentAdapter.defaultTerminalPollTimeoutMilliseconds,
        maximumAcceptedRunRecoveries: Int = OpenClawNativeAgentAdapter.defaultMaximumAcceptedRunRecoveries,
        responseBufferLimit: Int = AgentResponse.defaultBufferLimit,
        supportsVisionInput: Bool = false
    ) {
        precondition(maximumTerminalWaitPolls > 0)
        precondition(terminalPollTimeoutMilliseconds > 0)
        precondition(maximumAcceptedRunRecoveries >= 0)
        precondition(responseBufferLimit > 0)
        self.supervisor = supervisor
        self.dispatcher = dispatcher
        self.runClient = runClient
        self.sessionKey = sessionKey
        self.maximumTerminalWaitPolls = maximumTerminalWaitPolls
        self.terminalPollTimeoutMilliseconds = terminalPollTimeoutMilliseconds
        self.maximumAcceptedRunRecoveries = maximumAcceptedRunRecoveries
        self.responseBufferLimit = responseBufferLimit
        self.supportsVisionInput = supportsVisionInput
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

        return makeResponseStream(
            interactionID: request.interactionID,
            fallbackSessionKey: sessionKey
        ) { idempotencyKey in
            try await client.submit(
                message: request.text,
                sessionKey: sessionKey,
                idempotencyKey: idempotencyKey
            )
        }
    }

    public func responses(
        for request: VisionRequest
    ) async -> AsyncThrowingStream<AgentResponse, Error> {
        guard supportsVisionInput else {
            let limit = responseBufferLimit
            return AsyncThrowingStream(
                bufferingPolicy: .bufferingOldest(limit)
            ) { continuation in
                continuation.finish(
                    throwing: AWLError.capabilityUnavailable(
                        "OpenClaw vision input is not enabled for the selected runtime"
                    )
                )
            }
        }

        let client = runClient
        let sessionKey = sessionKey
        let attachment: OpenClawAgentAttachment
        do {
            attachment = try Self.makeImageAttachment(request.image)
        } catch {
            let limit = responseBufferLimit
            return AsyncThrowingStream(
                bufferingPolicy: .bufferingOldest(limit)
            ) { continuation in
                continuation.finish(throwing: error)
            }
        }

        return makeResponseStream(
            interactionID: request.interactionID,
            fallbackSessionKey: sessionKey
        ) { idempotencyKey in
            try await client.submit(
                message: request.prompt,
                sessionKey: sessionKey,
                idempotencyKey: idempotencyKey,
                attachments: [attachment]
            )
        }
    }

    nonisolated static func makeImageAttachment(
        _ image: ImageAttachment
    ) throws -> OpenClawAgentAttachment {
        // Callers can construct ImageAttachment with a custom larger limit.
        // The shipped OpenClaw path still enforces Core's canonical ceiling
        // before any base64/network allocation.
        guard image.data.count <= ImageAttachment.defaultMaximumBytes else {
            throw AWLError.capabilityUnavailable(
                "image payload exceeds configured limit"
            )
        }

        let mimeType: String
        let fileExtension: String
        switch image.format {
        case .jpeg:
            mimeType = "image/jpeg"
            fileExtension = "jpg"
        case .png:
            mimeType = "image/png"
            fileExtension = "png"
        }

        return OpenClawAgentAttachment(
            mimeType: mimeType,
            fileName: "capture.\(fileExtension)",
            content: image.data
        )
    }

    private func makeResponseStream(
        interactionID: InteractionID,
        fallbackSessionKey: String?,
        submit: @escaping @Sendable (String) async throws -> OpenClawAgentAccepted
    ) -> AsyncThrowingStream<AgentResponse, Error> {
        let client = runClient
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
                        try await submit(submissionIdentity.idempotencyKey)
                    }
                    await self.remember(
                        RunContext(
                            runID: accepted.runId,
                            sessionKey: accepted.sessionKey ?? fallbackSessionKey,
                            agentID: accepted.agentId
                        ),
                        for: interactionID
                    )

                    let (terminal, streamedText, recovered) =
                        try await self.waitForAcceptedRunTerminal(
                            client: client,
                            runID: accepted.runId,
                            interactionID: interactionID,
                            continuation: continuation
                        )

                    switch terminal.status {
                    case "ok":
                        // After transport recovery, post-reconnect live deltas
                        // are deliberately not emitted because their replay
                        // boundary is not authoritative. Require the terminal
                        // snapshot to repair everything after the last text
                        // emitted on the original transport.
                        if recovered,
                           Self.terminalReplyText(terminal.terminalReply) == nil {
                            throw OpenClawNativeAdapterError
                                .recoveredRunMissingTerminalReply
                        }

                        if let suffix = try Self.terminalReplySuffix(
                            streamedText: streamedText,
                            terminalReply: terminal.terminalReply
                        ) {
                            try Self.yieldResponse(
                                .textDelta(interactionID, suffix),
                                to: continuation
                            )
                        }
                        try Self.yieldResponse(
                            .completed(interactionID),
                            to: continuation
                        )
                        continuation.finish()
                    case "error":
                        // Gateway/provider details are untrusted text and may
                        // contain private model, account or session context.
                        try Self.yieldResponse(
                            .failed(interactionID, .agent(
                                Self.safeTerminalFailureMessage(terminal)
                            )),
                            to: continuation
                        )
                        continuation.finish()
                    case "timeout":
                        throw Self.terminalRunTimeoutError(terminal)
                    default:
                        throw OpenClawNativeAdapterError.unexpectedWaitStatus(
                            "unrecognized"
                        )
                    }

                    _ = await self.forget(interactionID)
                } catch is CancellationError {
                    // Once this stream task is cancelled, a remote abort issued
                    // on the same task can be cancelled before chat.abort is
                    // sent. Give the accepted remote mutation a bounded,
                    // cancellation-independent best-effort abort instead.
                    let abortTask = Task.detached {
                        await self.cancel(interactionID: interactionID)
                    }
                    await abortTask.value
                    continuation.finish()
                } catch {
                    if let context = await self.forget(interactionID) {
                        await client.finishUpdates(runID: context.runID)
                    }
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func waitForAcceptedRunTerminal(
        client: OpenClawAgentRunClient,
        runID: String,
        interactionID: InteractionID,
        continuation: AsyncThrowingStream<AgentResponse, Error>.Continuation
    ) async throws -> (
        terminal: OpenClawAgentWaitResult,
        streamedText: String,
        recovered: Bool
    ) {
        let accumulator = OpenClawEmittedTextAccumulator()
        var failedGeneration = await supervisor.transportGeneration
        var recoveryCount = 0
        var recovered = false

        while true {
            try Task.checkCancellation()

            let updates = await client.updates(runID: runID)
            let emitLiveDeltas = !recovered
            let streamTask = Task<Void, Error> {
                for try await update in updates {
                    guard case let .assistant(_, payload) = update,
                          let delta = Self.extractTextDelta(payload) else {
                        continue
                    }

                    // A new transport does not provide an authoritative replay
                    // boundary for run-local deltas. Suppress those deltas and
                    // reconcile against the terminal reply instead.
                    guard emitLiveDeltas else { continue }

                    try Self.yieldResponse(
                        .textDelta(interactionID, delta),
                        to: continuation
                    )
                    await accumulator.append(delta)
                }
            }

            do {
                let terminal = try await Self.withOwnedUpdateTask(streamTask) {
                    let terminal = try await self.waitUntilTerminal(
                        client: client,
                        runID: runID
                    )

                    // Once terminal status is known, close this exact
                    // generation's subscription and drain every update already
                    // accepted ahead of that boundary.
                    await client.finishUpdates(runID: runID)
                    try await streamTask.value
                    return terminal
                }

                return (
                    terminal,
                    await accumulator.snapshot(),
                    recovered
                )
            } catch is CancellationError {
                await client.finishUpdates(runID: runID)
                throw CancellationError()
            } catch {
                await client.finishUpdates(runID: runID)

                guard Self.isRecoverableAcceptedRunTransportError(error) else {
                    throw error
                }
                guard recoveryCount < maximumAcceptedRunRecoveries else {
                    throw OpenClawNativeAdapterError
                        .acceptedRunRecoveryLimitExceeded(
                            maximumRecoveries: maximumAcceptedRunRecoveries
                        )
                }

                recoveryCount += 1
                guard let nextGeneration = try await supervisor
                    .recoverAcceptedRunTransport(after: failedGeneration) else {
                    throw OpenClawNativeAdapterError
                        .acceptedRunRecoveryUnavailable
                }

                failedGeneration = nextGeneration
                recovered = true
            }
        }
    }

    nonisolated static func isRecoverableAcceptedRunTransportError(
        _ error: Error
    ) -> Bool {
        if let transport = error as? OpenClawTransportSendError {
            switch transport {
            case .staleGeneration, .deliveryUncertain:
                return true
            case .generationBindingUnavailable:
                return false
            }
        }

        guard let gateway = error as? AWLOpenClawError else {
            return false
        }
        switch gateway {
        case .notReady, .disconnected:
            return true
        default:
            // Application/Gateway errors (including run-not-found after a
            // server restart) are terminal for the accepted run. Never turn
            // them into a fresh mutation.
            return false
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

    nonisolated static func safeTerminalFailureMessage(
        _: OpenClawAgentWaitResult
    ) -> String {
        "OpenClaw agent run failed (details redacted)"
    }

    nonisolated static func terminalRunTimeoutError(
        _ result: OpenClawAgentWaitResult
    ) -> OpenClawNativeAdapterError {
        let phase: String?
        switch result.timeoutPhase {
        case "queue", "runtime", "provider":
            phase = result.timeoutPhase
        default:
            phase = nil
        }
        return .terminalRunTimedOut(
            timeoutPhase: phase,
            providerStarted: result.providerStarted,
            gatewayMessage: nil
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
    case acceptedRunRecoveryUnavailable
    case acceptedRunRecoveryLimitExceeded(maximumRecoveries: Int)
    case recoveredRunMissingTerminalReply
    case terminalReplyMismatch
    case terminalRunTimedOut(
        timeoutPhase: String?,
        providerStarted: Bool?,
        gatewayMessage: String?
    )
}
