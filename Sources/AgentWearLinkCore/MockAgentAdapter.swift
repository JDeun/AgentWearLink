import Foundation

public actor MockAgentAdapter: AgentAdapter {
    public typealias Handler = @Sendable (AgentRequest) async throws -> [AgentResponse]

    private let handler: Handler
    private let responseBufferLimit: Int
    private var cancelled: Set<InteractionID> = []
    private(set) var responseBufferOverflowCount = 0

    public init(
        responseBufferLimit: Int = AgentResponse.defaultBufferLimit,
        handler: @escaping Handler = { request in
        [
            .textDelta(request.interactionID, "echo: \(request.text)"),
            .completed(request.interactionID)
        ]
    }
    ) {
        precondition(responseBufferLimit > 0)
        self.responseBufferLimit = responseBufferLimit
        self.handler = handler
    }

    public func connect() async throws {}
    public func disconnect() async { cancelled.removeAll() }

    public func responses(
        for request: AgentRequest
    ) async -> AsyncThrowingStream<AgentResponse, Error> {
        let handler = self.handler
        let responseBufferLimit = self.responseBufferLimit

        return AsyncThrowingStream(
            bufferingPolicy: .bufferingOldest(responseBufferLimit)
        ) { continuation in
            let task = Task {
                do {
                    for response in try await handler(request) {
                        guard !Task.isCancelled else { break }
                        switch continuation.yield(response) {
                        case .enqueued:
                            break
                        case .dropped:
                            await self.recordResponseBufferOverflow()
                            continuation.finish(
                                throwing: AWLError.overloaded(
                                    "agent response stream buffer capacity exceeded"
                                )
                            )
                            return
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

    private func recordResponseBufferOverflow() {
        responseBufferOverflowCount += 1
    }

    public func cancel(interactionID: InteractionID) async {
        cancelled.insert(interactionID)
    }

    public func wasCancelled(_ id: InteractionID) -> Bool {
        cancelled.contains(id)
    }
}
