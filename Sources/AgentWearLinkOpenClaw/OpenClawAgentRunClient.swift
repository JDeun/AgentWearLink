import Foundation

public actor OpenClawAgentRunClient {
    private let dispatcher: OpenClawRPCDispatcher
    private let decoder = JSONDecoder()
    private let updateBufferLimit: Int
    private(set) var updateBufferOverflowCount = 0

    public init(
        dispatcher: OpenClawRPCDispatcher,
        updateBufferLimit: Int = OpenClawRPCDispatcher.defaultAgentEventBufferLimit
    ) {
        precondition(updateBufferLimit > 0)
        self.dispatcher = dispatcher
        self.updateBufferLimit = updateBufferLimit
    }

    public func submit(
        message: String,
        sessionKey: String?,
        idempotencyKey: String,
        attachments: [OpenClawAgentAttachment]? = nil
    ) async throws -> OpenClawAgentAccepted {
        let response = try await dispatcher.request(
            method: "agent",
            params: OpenClawAgentParams(
                message: message,
                sessionKey: sessionKey,
                idempotencyKey: idempotencyKey,
                attachments: attachments
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
        runID: String
    ) async -> AsyncThrowingStream<OpenClawAgentRunUpdate, Error> {
        let events = await dispatcher.agentEvents(runID: runID)

        return AsyncThrowingStream(
            bufferingPolicy: .bufferingNewest(updateBufferLimit)
        ) { continuation in
            let task = Task {
                do {
                    for try await event in events {
                        let update: OpenClawAgentRunUpdate
                        switch event.stream {
                        case "assistant":
                            update = .assistant(runID: runID, payload: event.data)
                        case "tool":
                            update = .tool(runID: runID, payload: event.data)
                        case "lifecycle":
                            update = .lifecycle(runID: runID, payload: event.data)
                        default:
                            continue
                        }

                        switch continuation.yield(update) {
                        case .enqueued:
                            break
                        case .dropped:
                            await self.recordUpdateBufferOverflow()
                            throw OpenClawAgentRunError.updateBufferOverflow(runID)
                        case .terminated:
                            return
                        @unknown default:
                            return
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

    public func finishUpdates(runID: String) async {
        await dispatcher.finishAgentEvents(runID: runID)
    }

    private func recordUpdateBufferOverflow() {
        updateBufferOverflowCount += 1
    }

    private func decodePayload<T: Decodable>(
        _ response: OpenClawResponseEnvelope,
        as type: T.Type
    ) throws -> T {
        guard response.ok else {
            throw AWLOpenClawError.gateway(
                code: OpenClawGatewayErrorCodePolicy.safeCode(response.error?.code),
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
    case updateBufferOverflow(String)
}
