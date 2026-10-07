import Foundation

public actor OpenClawRPCDispatcher {
    private enum RequestDeliveryState {
        case admitted
        case sending
        case sent
    }

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
    private var deliveryStates: [String: RequestDeliveryState] = [:]
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
        guard receiveTask != nil else {
            throw AWLOpenClawError.disconnected
        }
        let requestGeneration = generation

        guard await state.connectionState == .ready else {
            throw AWLOpenClawError.notReady
        }
        guard isActive(generation: requestGeneration) else {
            throw AWLOpenClawError.disconnected
        }

        if let textParams = params as? OpenClawAgentParams {
            try await state.validateOutboundFrameSize(textParams.message.utf8.count)
            guard isActive(generation: requestGeneration) else {
                throw AWLOpenClawError.disconnected
            }
        }

        let id = UUID().uuidString
        let frame = OpenClawRequestFrame(id: id, method: method, params: params)
        let data = try encoder.encode(frame)
        try await state.validateOutboundFrameSize(data.count)
        guard isActive(generation: requestGeneration) else {
            throw AWLOpenClawError.disconnected
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw OpenClawFrameError.malformedFrame
        }

        let connectionGeneration = await socket.currentConnectionGeneration()
        guard isActive(generation: requestGeneration) else {
            throw AWLOpenClawError.disconnected
        }

        try await registry.register(id: id, method: method)
        guard isActive(generation: requestGeneration) else {
            await registry.remove(id: id)
            throw AWLOpenClawError.disconnected
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                responses[id] = continuation
                deliveryStates[id] = .admitted

                let task = Task {
                    guard await self.beginSend(
                        id: id,
                        generation: requestGeneration
                    ) else {
                        return
                    }

                    do {
                        try await socket.send(
                            text: text,
                            connectionGeneration: connectionGeneration
                        )
                        await self.markSent(id: id)
                    } catch is CancellationError {
                        await self.recordDefinitelyNotSent(
                            id: id,
                            generation: requestGeneration,
                            error: CancellationError()
                        )
                        return
                    } catch let error as AWLOpenClawError
                        where error == .disconnected {
                        await self.recordDefinitelyNotSent(
                            id: id,
                            generation: requestGeneration,
                            error: error
                        )
                        return
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
                        // Completion, cancellation, or stop owns terminal cleanup.
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
        for task in ownedRequestTasks {
            task.cancel()
        }

        receiveTask?.cancel()
        receiveTask = nil
        lastActivityMilliseconds = nil

        for task in ownedRequestTasks {
            await task.value
        }

        await failAllForTransportLoss(
            definitelyNotSentError: AWLOpenClawError.disconnected
        )
        requestTasks.removeAll(keepingCapacity: false)

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
                let frame = try router.decode(
                    Data(text.utf8),
                    maximumBytes: inboundMaximumBytes
                )

                switch frame {
                case let .response(response):
                    try await state.observeSequence(nil)
                    _ = try await registry.resolve(id: response.id)
                    requestTasks.removeValue(forKey: response.id)?.cancel()
                    deliveryStates[response.id] = nil
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
            await failAllForTransportLoss(definitelyNotSentError: error)
            for continuation in eventContinuations.values {
                continuation.finish(throwing: error)
            }
            eventContinuations.removeAll(keepingCapacity: false)
        }
        receiveTask = nil
    }

    private func isActive(generation expected: UInt64) -> Bool {
        generation == expected && receiveTask != nil
    }

    private func beginSend(id: String, generation expected: UInt64) -> Bool {
        guard isActive(generation: expected),
              responses[id] != nil,
              !Task.isCancelled else {
            return false
        }
        deliveryStates[id] = .sending
        return true
    }

    private func markSent(id: String) {
        guard responses[id] != nil else { return }
        deliveryStates[id] = .sent
    }

    private func recordDefinitelyNotSent(
        id: String,
        generation expected: UInt64,
        error: Error
    ) async {
        guard responses[id] != nil else { return }
        deliveryStates[id] = .admitted

        // If stop/reconnect already retired this dispatcher generation, stop()
        // owns the terminal result after all owned send tasks have drained.
        guard generation == expected else { return }
        await fail(id: id, error: error)
    }

    private func removeEventSubscriber(_ id: UUID) {
        eventContinuations[id] = nil
    }

    private func cancel(id: String) async {
        requestTasks.removeValue(forKey: id)?.cancel()
        let delivery = deliveryStates.removeValue(forKey: id)
        await registry.remove(id: id)

        let error: Error
        switch delivery {
        case .sending?, .sent?:
            error = AWLOpenClawError.deliveryUncertain
        case .admitted?, nil:
            error = CancellationError()
        }

        responses.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func fail(id: String, error: Error) async {
        requestTasks.removeValue(forKey: id)?.cancel()
        deliveryStates[id] = nil
        await registry.remove(id: id)
        responses.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func failAllForTransportLoss(
        definitelyNotSentError: Error
    ) async {
        let pending = await registry.drainForDisconnect()
        for item in pending {
            requestTasks.removeValue(forKey: item.id)?.cancel()
            let delivery = deliveryStates.removeValue(forKey: item.id)

            let error: Error
            switch delivery {
            case .sending?, .sent?:
                error = AWLOpenClawError.deliveryUncertain
            case .admitted?, nil:
                error = definitelyNotSentError
            }

            responses.removeValue(forKey: item.id)?.resume(throwing: error)
        }
    }
}

public enum OpenClawRPCDispatcherError: Error, Sendable, Equatable {
    case deadlineExceeded
}
