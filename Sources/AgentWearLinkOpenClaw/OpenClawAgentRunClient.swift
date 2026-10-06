import Foundation

public actor OpenClawAgentRunClient {
    private let dispatcher: OpenClawRPCDispatcher
    private let decoder = JSONDecoder()

    public init(dispatcher: OpenClawRPCDispatcher) {
        self.dispatcher = dispatcher
    }

    public func submit(
        message: String,
        sessionKey: String?,
        idempotencyKey: String
    ) async throws -> OpenClawAgentAccepted {
        let response = try await dispatcher.request(
            method: "agent",
            params: OpenClawAgentParams(
                message: message,
                sessionKey: sessionKey,
                idempotencyKey: idempotencyKey
            )
        )
        return try decodePayload(response, as: OpenClawAgentAccepted.self)
    }

    public func wait(
        runID: String,
        timeoutMilliseconds: Int? = nil
    ) async throws -> OpenClawAgentWaitResult {
        let response = try await dispatcher.request(
            method: "agent.wait",
            params: OpenClawAgentWaitParams(
                runId: runID,
                timeoutMs: timeoutMilliseconds
            )
        )
        return try decodePayload(response, as: OpenClawAgentWaitResult.self)
    }

    public func cancel(
        runID: String,
        sessionKey: String,
        agentID: String? = nil
    ) async throws {
        let response = try await dispatcher.request(
            method: "chat.abort",
            params: OpenClawChatAbortParams(
                sessionKey: sessionKey,
                runId: runID,
                agentId: agentID
            )
        )
        let result = try decodePayload(
            response,
            as: OpenClawChatAbortResult.self
        )

        guard result.aborted,
              result.runIds == nil || result.runIds?.contains(runID) == true else {
            throw OpenClawAgentRunError.abortNotConfirmed(runID)
        }
    }

    public func updates(
        from events: AsyncThrowingStream<OpenClawEventEnvelope, Error>,
        runID: String
    ) -> AsyncThrowingStream<OpenClawAgentRunUpdate, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await envelope in events {
                        guard envelope.event == "agent",
                              let payload = envelope.payload else {
                            continue
                        }
                        let event = try decode(payload, as: OpenClawAgentEvent.self)
                        guard event.runId == runID else { continue }

                        switch event.stream {
                        case "assistant":
                            continuation.yield(
                                .assistant(runID: runID, payload: event.data)
                            )
                        case "tool":
                            continuation.yield(
                                .tool(runID: runID, payload: event.data)
                            )
                        case "lifecycle":
                            continuation.yield(
                                .lifecycle(runID: runID, payload: event.data)
                            )
                        default:
                            continue
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func decodePayload<T: Decodable>(
        _ response: OpenClawResponseEnvelope,
        as type: T.Type
    ) throws -> T {
        guard response.ok else {
            throw AWLOpenClawError.gateway(
                code: response.error?.code ?? "UNKNOWN",
                retryable: response.error?.retryable ?? false
            )
        }
        guard let payload = response.payload else {
            throw OpenClawAgentRunError.missingPayload
        }
        return try decode(payload, as: type)
    }

    private func decode<T: Decodable>(
        _ value: JSONValue,
        as type: T.Type
    ) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try decoder.decode(type, from: data)
    }
}

public enum OpenClawAgentRunError: Error, Sendable, Equatable {
    case missingPayload
    case abortNotConfirmed(String)
}
