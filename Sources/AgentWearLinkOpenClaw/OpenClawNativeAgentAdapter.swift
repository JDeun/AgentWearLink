import AgentWearLinkCore
import Foundation

public actor OpenClawNativeAgentAdapter: AgentAdapter {
    private let connection: OpenClawGatewayConnection
    private let dispatcher: OpenClawRPCDispatcher
    private let runClient: OpenClawAgentRunClient
    private let appVersion: String
    private let credentials: OpenClawConnectCredentials
    private let sessionKey: String?
    private var runIDs: [InteractionID: String] = [:]

    public init(
        connection: OpenClawGatewayConnection,
        dispatcher: OpenClawRPCDispatcher,
        runClient: OpenClawAgentRunClient,
        appVersion: String,
        credentials: OpenClawConnectCredentials = .init(),
        sessionKey: String? = nil
    ) {
        self.connection = connection
        self.dispatcher = dispatcher
        self.runClient = runClient
        self.appVersion = appVersion
        self.credentials = credentials
        self.sessionKey = sessionKey
    }

    public func connect() async throws {
        _ = try await connection.connect(
            appVersion: appVersion,
            credentials: credentials
        )
        await dispatcher.start()
    }

    public func disconnect() async {
        await dispatcher.stop()
        await connection.disconnect()
        runIDs.removeAll(keepingCapacity: false)
    }

    public func responses(
        for request: AgentRequest
    ) async -> AsyncThrowingStream<AgentResponse, Error> {
        let events = await dispatcher.events()
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
                        accepted.runId,
                        for: request.interactionID
                    )

                    let updates = await client.updates(
                        from: events,
                        runID: accepted.runId
                    )
                    let streamTask = Task {
                        do {
                            for try await update in updates {
                                if case let .assistant(_, payload) = update,
                                   let delta = Self.extractTextDelta(payload) {
                                    continuation.yield(
                                        .textDelta(request.interactionID, delta)
                                    )
                                }
                            }
                        } catch {
                            // Terminal wait owns final success/failure.
                        }
                    }

                    let terminal = try await self.waitUntilTerminal(
                        client: client,
                        runID: accepted.runId
                    )
                    streamTask.cancel()

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

                    await self.forget(request.interactionID)
                } catch is CancellationError {
                    await self.cancel(interactionID: request.interactionID)
                    continuation.finish()
                } catch {
                    await self.forget(request.interactionID)
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func cancel(interactionID: InteractionID) async {
        guard let runID = runIDs.removeValue(forKey: interactionID) else {
            return
        }
        try? await runClient.cancel(runID: runID)
    }

    private func remember(
        _ runID: String,
        for interactionID: InteractionID
    ) {
        runIDs[interactionID] = runID
    }

    private func forget(_ interactionID: InteractionID) {
        runIDs[interactionID] = nil
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

    nonisolated private static func extractTextDelta(
        _ payload: JSONValue?
    ) -> String? {
        guard case let .object(object)? = payload else { return nil }

        for key in ["delta", "text"] {
            if case let .string(value)? = object[key], !value.isEmpty {
                return value
            }
        }
        return nil
    }
}

public enum OpenClawNativeAdapterError: Error, Sendable, Equatable {
    case unexpectedWaitStatus(String)
}
