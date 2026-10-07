import AgentWearLinkCore
import Foundation

public actor OpenClawNativeAgentAdapter: AgentAdapter {
    private let supervisor: OpenClawGatewaySupervisor
    private let dispatcher: OpenClawRPCDispatcher
    private let runClient: OpenClawAgentRunClient
    private struct RunContext: Sendable {
        let runID: String
        let sessionKey: String?
        let agentID: String?
    }

    private let sessionKey: String?
    private var runs: [InteractionID: RunContext] = [:]

    public init(
        supervisor: OpenClawGatewaySupervisor,
        dispatcher: OpenClawRPCDispatcher,
        runClient: OpenClawAgentRunClient,
        sessionKey: String? = nil
    ) {
        self.supervisor = supervisor
        self.dispatcher = dispatcher
        self.runClient = runClient
        self.sessionKey = sessionKey
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

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let accepted = try await client.submit(
                        message: request.text,
                        sessionKey: sessionKey,
                        idempotencyKey: request.interactionID.rawValue.uuidString
                    )
                    await self.remember(
                        RunContext(
                            runID: accepted.runId,
                            sessionKey: accepted.sessionKey ?? sessionKey,
                            agentID: accepted.agentId
                        ),
                        for: request.interactionID
                    )

                    let updates = await client.updates(runID: accepted.runId)
                    let streamTask = Task {
                        for try await update in updates {
                            if case let .assistant(_, payload) = update,
                               let delta = Self.extractTextDelta(payload) {
                                continuation.yield(
                                    .textDelta(request.interactionID, delta)
                                )
                            }
                        }
                    }

                    let terminal = try await self.waitUntilTerminal(
                        client: client,
                        runID: accepted.runId
                    )
                    await client.finishUpdates(runID: accepted.runId)
                    try await streamTask.value

                    switch terminal.status {
                    case "ok":
                        continuation.yield(.completed(request.interactionID))
                        continuation.finish()
                    case "error":
                        let message = terminal.error
                            ?? terminal.stopReason
                            ?? "OpenClaw agent run failed"
                        continuation.yield(
                            .failed(request.interactionID, .agent(message))
                        )
                        continuation.finish()
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

    public func cancel(interactionID: InteractionID) async {
        guard let context = runs.removeValue(forKey: interactionID) else {
            return
        }

        if let sessionKey = context.sessionKey {
            try? await runClient.cancel(
                runID: context.runID,
                sessionKey: sessionKey,
                agentID: context.agentID
            )
        }
        await runClient.finishUpdates(runID: context.runID)
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

    private func waitUntilTerminal(
        client: OpenClawAgentRunClient,
        runID: String
    ) async throws -> OpenClawAgentWaitResult {
        while true {
            try Task.checkCancellation()
            let result = try await client.wait(
                runID: runID,
                timeoutMilliseconds: 30_000
            )
            switch result.status {
            case "timeout", "pending":
                continue
            default:
                return result
            }
        }
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
    case unexpectedWaitStatus(String)
}
