import Foundation

public actor OpenClawRPCDispatcher {
    private let socket: any OpenClawWebSocket
    private let state: OpenClawGatewayState
    private let registry: OpenClawRPCRegistry
    private let router = OpenClawFrameRouter()
    private let encoder = JSONEncoder()

    private var responses: [String: CheckedContinuation<OpenClawResponseEnvelope, Error>] = [:]
    private var eventContinuation: AsyncThrowingStream<OpenClawEventEnvelope, Error>.Continuation?
    private var receiveTask: Task<Void, Never>?

    public init(
        socket: any OpenClawWebSocket,
        state: OpenClawGatewayState,
        registry: OpenClawRPCRegistry = .init()
    ) {
        self.socket = socket
        self.state = state
        self.registry = registry
    }

    public func events() -> AsyncThrowingStream<OpenClawEventEnvelope, Error> {
        AsyncThrowingStream { continuation in
            self.eventContinuation = continuation
        }
    }

    public func start() {
        guard receiveTask == nil else { return }
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    public func request<Params: Encodable & Sendable>(
        method: String,
        params: Params
    ) async throws -> OpenClawResponseEnvelope {
        guard await state.connectionState == .ready else {
            throw AWLOpenClawError.notReady
        }

        let id = UUID().uuidString
        let frame = OpenClawRequestFrame(id: id, method: method, params: params)
        let data = try encoder.encode(frame)
        try await state.validateOutboundFrameSize(data.count)
        guard let text = String(data: data, encoding: .utf8) else {
            throw OpenClawFrameError.malformedFrame
        }

        try await registry.register(id: id, method: method)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                responses[id] = continuation
                Task {
                    do {
                        try await socket.send(text: text)
                    } catch {
                        await self.fail(id: id, error: error)
                    }
                }
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    public func stop() async {
        receiveTask?.cancel()
        receiveTask = nil
        await failAll(AWLOpenClawError.disconnected)
        eventContinuation?.finish()
        eventContinuation = nil
    }

    private func receiveLoop() async {
        do {
            while !Task.isCancelled {
                let text = try await socket.receive()
                let frame = try router.decode(Data(text.utf8))

                switch frame {
                case let .response(response):
                    try await state.observeSequence(nil)
                    _ = try await registry.resolve(id: response.id)
                    responses.removeValue(forKey: response.id)?
                        .resume(returning: response)

                case let .event(event):
                    try await state.observeSequence(event.seq)
                    eventContinuation?.yield(event)
                }
            }
        } catch is CancellationError {
            // stop() owns terminal signaling.
        } catch {
            await failAll(error)
            eventContinuation?.finish(throwing: error)
            eventContinuation = nil
        }
    }

    private func cancel(id: String) async {
        await registry.remove(id: id)
        responses.removeValue(forKey: id)?
            .resume(throwing: CancellationError())
    }

    private func fail(id: String, error: Error) async {
        await registry.remove(id: id)
        responses.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func failAll(_ error: Error) async {
        let pending = await registry.drainForDisconnect()
        for item in pending {
            responses.removeValue(forKey: item.id)?.resume(throwing: error)
        }
    }
}
