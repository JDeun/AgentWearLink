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
    private var requestTasks: [String: Task<Void, Never>] = [:]
    private var sendStarted: Set<String> = []
    private var generation: UInt64 = 0
    private var lastActivityMilliseconds: Int64?
    private let nowMilliseconds: @Sendable () -> Int64
    private let requestTimeout: Duration
    private let inboundMaximumBytes: Int

    public init(
        socket: any OpenClawWebSocket,
        state: OpenClawGatewayState,
        registry: OpenClawRPCRegistry = .init(),
        requestTimeout: Duration = .seconds(30),
        inboundMaximumBytes: Int = OpenClawFrameRouter.defaultInboundMaximumBytes,
        nowMilliseconds: @escaping @Sendable () -> Int64 = {
            Int64(ProcessInfo.processInfo.systemUptime * 1_000)
        }
    ) {
        self.socket = socket
        self.state = state
        precondition(requestTimeout > .zero)
        self.registry = registry
        self.requestTimeout = requestTimeout
        precondition(inboundMaximumBytes > 0)
        self.inboundMaximumBytes = inboundMaximumBytes
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
        generation &+= 1
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
        guard receiveTask != nil,
              await state.connectionState == .ready else {
            throw AWLOpenClawError.notReady
        }

        // Capture transport identity before validating the authenticated state.
        // If reconnect retires this transport at any later point, the bound send
        // below rejects rather than resolving the socket actor's new task.
        guard let transportGeneration = await socket.transportGeneration() else {
            throw OpenClawTransportSendError.generationBindingUnavailable
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
        let requestGeneration = generation

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                responses[id] = continuation

                let task = Task {
                    guard await self.markSendStarted(
                        id: id,
                        generation: requestGeneration
                    ) else {
                        return
                    }

                    do {
                        try Task.checkCancellation()
                        try await socket.send(
                            text: text,
                            expectedGeneration: transportGeneration
                        )

                        try await Task.sleep(for: requestTimeout)
                        await self.fail(
                            id: id,
                            error: OpenClawRPCDispatcherError.deadlineExceeded
                        )
                    } catch is CancellationError {
                        // Response completion, explicit cancellation, or stop()
                        // owns terminal signaling for a cancelled request task.
                    } catch {
                        await self.fail(id: id, error: error)
                    }
                }
                requestTasks[id] = task
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    public func stop() async {
        generation &+= 1

        let ownedRequestTasks = Array(requestTasks.values)
        requestTasks.removeAll(keepingCapacity: false)
        for task in ownedRequestTasks {
            task.cancel()
        }

        receiveTask?.cancel()
        receiveTask = nil
        lastActivityMilliseconds = nil

        // Wait until every owned send task has observed cancellation or returned
        // from its generation-bound socket send before classifying outcomes.
        for task in ownedRequestTasks {
            await task.value
        }

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
                let frame = try router.decode(Data(text.utf8), maximumBytes: inboundMaximumBytes)

                switch frame {
                case let .response(response):
                    try await state.observeSequence(nil)
                    _ = try await registry.resolve(id: response.id)
                    sendStarted.remove(response.id)
                    requestTasks.removeValue(forKey: response.id)?.cancel()
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

    private func markSendStarted(
        id: String,
        generation expected: UInt64
    ) -> Bool {
        guard generation == expected,
              responses[id] != nil,
              requestTasks[id] != nil,
              !Task.isCancelled else {
            return false
        }
        sendStarted.insert(id)
        return true
    }

    private func removeEventSubscriber(_ id: UUID) {
        eventContinuations[id] = nil
    }

    private func cancel(id: String) async {
        let mayHaveBeenSent = sendStarted.remove(id) != nil
        requestTasks.removeValue(forKey: id)?.cancel()
        await registry.remove(id: id)
        responses.removeValue(forKey: id)?.resume(
            throwing: mayHaveBeenSent
                ? OpenClawTransportSendError.deliveryUncertain
                : CancellationError()
        )
    }

    private func fail(id: String, error: Error) async {
        sendStarted.remove(id)
        requestTasks.removeValue(forKey: id)
        await registry.remove(id: id)
        responses.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func failAll(_ error: Error) async {
        let pending = await registry.drainForDisconnect()
        for item in pending {
            requestTasks.removeValue(forKey: item.id)?.cancel()
            let mayHaveBeenSent = sendStarted.remove(item.id) != nil
            responses.removeValue(forKey: item.id)?.resume(
                throwing: mayHaveBeenSent
                    ? OpenClawTransportSendError.deliveryUncertain
                    : error
            )
        }
    }
}


public enum OpenClawRPCDispatcherError: Error, Sendable, Equatable {
    case deadlineExceeded
}
