import Foundation

public actor MockAgentAdapter: AgentAdapter {
    public typealias Handler = @Sendable (AgentRequest) async throws -> [AgentResponse]

    private let handler: Handler
    private var cancelled: Set<InteractionID> = []

    public init(handler: @escaping Handler = { request in
        [
            .textDelta(request.interactionID, "echo: \(request.text)"),
            .completed(request.interactionID)
        ]
    }) {
        self.handler = handler
    }

    public func connect() async throws {}
    public func disconnect() async { cancelled.removeAll() }

    public func responses(
        for request: AgentRequest
    ) async -> AsyncThrowingStream<AgentResponse, Error> {
        let handler = self.handler

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for response in try await handler(request) {
                        guard !Task.isCancelled else { break }
                        continuation.yield(response)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func cancel(interactionID: InteractionID) async {
        cancelled.insert(interactionID)
    }

    public func wasCancelled(_ id: InteractionID) -> Bool {
        cancelled.contains(id)
    }
}
