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
        let response: OpenClawResponseEnvelope
        do {
            response = try await dispatcher.request(
                method: "agent",
                params: OpenClawAgentParams(
                    message: message,
                    sessionKey: sessionKey,
                    idempotencyKey: idempotencyKey
                )
            )
        } catch is CancellationError {
            // Dispatcher cancellation before transport handoff is known-not-sent.
            // Preserve cancellation semantics so lifecycle interruption does not
            // become a second user-visible failure.
            throw CancellationError()
        } catch let error as OpenClawTransportSendError {
            switch error {
            case .deliveryUncertain:
                throw OpenClawAgentSubmissionError.executionUncertain(
                    idempotencyKey: idempotencyKey
                )
            case .staleGeneration, .generationBindingUnavailable:
                throw OpenClawAgentSubmissionError.definitelyNotSent(
                    idempotencyKey: idempotencyKey
                )
            }
        } catch let error as OpenClawRPCDispatcherError {
            switch error {
            case .deadlineExceeded:
                // RPC deadlines start only after the generation-bound send has
                // completed, so admission/execution can no longer be disproved.
                throw OpenClawAgentSubmissionError.executionUncertain(
                    idempotencyKey: idempotencyKey
                )
            }
        } catch let error as AWLOpenClawError {
            switch error {
            case .disconnected, .notReady:
                // The dispatcher converts transport loss after send handoff to
                // deliveryUncertain. Reaching these errors therefore means the
                // mutating frame was never handed to the transport.
                throw OpenClawAgentSubmissionError.definitelyNotSent(
                    idempotencyKey: idempotencyKey
                )
            default:
                throw error
            }
        }

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

public enum OpenClawAgentSubmissionError: Error, Sendable, Equatable {
    /// The dispatcher can prove the mutating frame did not cross the transport
    /// boundary. A higher layer may choose a new explicit submission, but this
    /// client never retries automatically.
    case definitelyNotSent(idempotencyKey: String)

    /// The mutating frame may have been admitted or executed remotely, but its
    /// acceptance response was not observed. Never replay automatically.
    case executionUncertain(idempotencyKey: String)
}

public enum OpenClawAgentRunError: Error, Sendable, Equatable {
    case missingPayload
    case abortNotConfirmed(String)
}
