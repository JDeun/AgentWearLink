import Foundation

public actor OpenClawRPCDispatcher {
    private let socket: any OpenClawWebSocket
    private let state: OpenClawGatewayState
    private let registry: OpenClawRPCRegistry
    private let router = OpenClawFrameRouter()
    private let encoder = JSONEncoder()

    private var responses: [String: CheckedContinuation<OpenClawResponseEnvelope, Error>] = [:]
    private var eventContinuations: [
        UUID: AsyncThrowingStream<OpenClawEventEnvelope, Error>.Continuation
    ] = [:]
    private var receiveTask: Task<Void, Never>?
    private var lastActivityMilliseconds: Int64?
    private let nowMilliseconds: @Sendable () -> Int64
    private let requestTimeout: Duration

    public init(
        socket: any OpenClawWebSocket,
        state: OpenClawGatewayState,
        registry: OpenClawRPCRegistry = .init(),
        requestTimeout: Duration = .seconds(30),
        nowMilliseconds: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1_000)
        }
    ) {
        self.socket = socket
        self.state = state
        precondition(requestTimeout > .zero)
        self.registry = registry
        self.requestTimeout = requestTimeout
        self.nowMilliseconds = nowMilliseconds
    }

    public func events() -> AsyncThrowingStream<OpenClawEventEnvelope, Error> {
        let id = UUID()
        return AsyncThrowingStream { continuation in
            eventContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeEventSubscriber(id) }
            }
        }
    }

    public func start() {
        guard receiveTask == nil else { return }
        lastActivityMilliseconds = nowMilliseconds()
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    public var isRunning: Bool {
        receiveTask != nil
    }

    public func isStale(
        timeoutMilliseconds: Int,
        now explicitNow: Int64? = nil
    ) -> Bool {
        guard timeoutMilliseconds > 0,
              let lastActivityMilliseconds else {
            return false
        }
        let now = explicitNow ?? nowMilliseconds()
        return now - lastActivityMilliseconds > Int64(timeoutMilliseconds)
    }

    public func request<Params: Encodable & Sendable>(
        method: String,
        params: Params
    ) async throws -> OpenClawResponseEnvelope {
        guard await state.connectionState == .ready else {
            throw AWLOpenClawError.notReady
        }

        if let textParams = params as? OpenClawAgentParams {
            try await state.validateOutboundFrameSize(textParams.message.utf8.count)
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
                        return
                    }

                    do {
                        try await Task.sleep(for: requestTimeout)
                        await self.fail(
                            id: id,
                            error: OpenClawRPCDispatcherError.deadlineExceeded
                        )
                    } catch is CancellationError {
                        // Request completion/cancellation owns cleanup.
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
        lastActivityMilliseconds = nil
        await failAll(AWLOpenClawError.disconnected)
        for continuation in eventContinuations.values {
            continuation.finish()
        }
        eventContinuations.removeAll(keepingCapacity: false)
    }

    private func receiveLoop() async {
        do {
            while !Task.isCancelled {
                let text = try await socket.receive()
                lastActivityMilliseconds = nowMilliseconds()
                let frame = try router.decode(Data(text.utf8))

                switch frame {
                case let .response(response):
                    try await state.observeSequence(nil)
                    _ = try await registry.resolve(id: response.id)
                    responses.removeValue(forKey: response.id)?
                        .resume(returning: response)

                case let .event(event):
                    try await state.observeSequence(event.seq)
                    for continuation in eventContinuations.values {
                        continuation.yield(event)
                    }
                }
            }
        } catch is CancellationError {
            // stop() owns terminal signaling.
        } catch {
            await state.disconnect()
            await failAll(error)
            for continuation in eventContinuations.values {
                continuation.finish(throwing: error)
            }
            eventContinuations.removeAll(keepingCapacity: false)
        }
        receiveTask = nil
    }

    private func removeEventSubscriber(_ id: UUID) {
        eventContinuations[id] = nil
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


public enum OpenClawRPCDispatcherError: Error, Sendable, Equatable {
    case deadlineExceeded
}
