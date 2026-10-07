import Foundation

public actor OpenClawRPCDispatcher {
    private struct ReceiveTaskEntry {
        let generation: UInt64
        let task: Task<Void, Never>
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
    private var receiveTask: ReceiveTaskEntry?
    private var requestTasks: [String: Task<Void, Never>] = [:]
    private var sendStarted: Set<String> = []
    private var generation: UInt64 = 0
    private var stopping = false
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
        guard !stopping, receiveTask == nil else { return }
        generation &+= 1
        let receiveGeneration = generation
        lastActivityMilliseconds = nowMilliseconds()
        let task = Task { [weak self] in
            await self?.receiveLoop(generation: receiveGeneration)
        }
        receiveTask = ReceiveTaskEntry(
            generation: receiveGeneration,
            task: task
        )
    }

    public var isRunning: Bool {
        !stopping && receiveTask != nil
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
        guard !stopping,
              receiveTask != nil else {
            throw AWLOpenClawError.notReady
        }
        let requestGeneration = generation

        guard await state.connectionState == .ready else {
            throw AWLOpenClawError.notReady
        }
        guard isActiveRequestGeneration(requestGeneration) else {
            throw AWLOpenClawError.disconnected
        }

        // Capture transport identity while the authenticated dispatcher generation
        // is still active. Every actor hop below is followed by the same fence so
        // stop() cannot retire this request and let it resume into a later session.
        let capturedTransportGeneration = await socket.transportGeneration()
        guard isActiveRequestGeneration(requestGeneration) else {
            throw AWLOpenClawError.disconnected
        }
        guard let transportGeneration = capturedTransportGeneration else {
            throw OpenClawTransportSendError.generationBindingUnavailable
        }

        if let textParams = params as? OpenClawAgentParams {
            try await state.validateOutboundFrameSize(textParams.message.utf8.count)
            guard isActiveRequestGeneration(requestGeneration) else {
                throw AWLOpenClawError.disconnected
            }
        }

        let id = UUID().uuidString
        let frame = OpenClawRequestFrame(id: id, method: method, params: params)
        let data = try encoder.encode(frame)
        try await state.validateOutboundFrameSize(data.count)
        guard isActiveRequestGeneration(requestGeneration) else {
            throw AWLOpenClawError.disconnected
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw OpenClawFrameError.malformedFrame
        }

        try await registry.register(id: id, method: method)
        guard isActiveRequestGeneration(requestGeneration) else {
            // register() is a separate actor hop. stop() may drain the old
            // registry while registration is suspended and the late insert can
            // otherwise survive into a retired dispatcher generation.
            await registry.remove(id: id)
            throw AWLOpenClawError.disconnected
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                responses[id] = continuation

                let task = Task {
                    var sendCompleted = false

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
                        sendCompleted = true

                        try await Task.sleep(for: requestTimeout)
                        await self.fail(
                            id: id,
                            error: OpenClawRPCDispatcherError.deadlineExceeded
                        )
                    } catch is CancellationError {
                        if !sendCompleted {
                            // Cancellation observed before transport handoff is a
                            // definite-not-sent result.
                            await self.fail(
                                id: id,
                                error: CancellationError()
                            )
                        }
                        // After a successful send, response completion, explicit
                        // cancellation, or stop() owns terminal classification.
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
        guard !stopping else { return }
        stopping = true
        defer { stopping = false }

        generation &+= 1

        let ownedRequestTasks = Array(requestTasks.values)
        requestTasks.removeAll(keepingCapacity: false)
        for task in ownedRequestTasks {
            task.cancel()
        }

        let retiringReceiveTask = receiveTask
        retiringReceiveTask?.task.cancel()
        lastActivityMilliseconds = nil

        // Wait until every owned send task has observed cancellation or returned
        // from its generation-bound socket send before classifying outcomes.
        for task in ownedRequestTasks {
            await task.value
        }

        // Keep the old receive task installed until it has actually exited. This
        // makes start() single-reader safe even if receive() ignores cancellation
        // until the transport itself is retired.
        if let retiringReceiveTask {
            await retiringReceiveTask.task.value
        }

        await failAll(AWLOpenClawError.disconnected)
        for continuation in eventContinuations.values {
            continuation.finish()
        }
        eventContinuations.removeAll(keepingCapacity: false)
    }

    private func receiveLoop(generation receiveGeneration: UInt64) async {
        do {
            while !Task.isCancelled {
                let text = try await socket.receive()

                guard isCurrentReceiveGeneration(receiveGeneration) else {
                    break
                }

                lastActivityMilliseconds = nowMilliseconds()
                let frame = try router.decode(
                    Data(text.utf8),
                    maximumBytes: inboundMaximumBytes
                )

                switch frame {
                case let .response(response):
                    try await state.observeSequence(nil)
                    guard isCurrentReceiveGeneration(receiveGeneration) else {
                        break
                    }

                    // Once registry resolution succeeds, the response wins a race
                    // with stop(). Completing it cannot affect a newer receiver
                    // because stop() keeps this receive task installed until exit.
                    _ = try await registry.resolve(id: response.id)
                    sendStarted.remove(response.id)
                    requestTasks.removeValue(forKey: response.id)?.cancel()
                    responses.removeValue(forKey: response.id)?
                        .resume(returning: response)

                case let .event(event):
                    try await state.observeSequence(event.seq)
                    guard isCurrentReceiveGeneration(receiveGeneration) else {
                        break
                    }
                    for continuation in eventContinuations.values {
                        continuation.yield(event)
                    }
                }
            }
        } catch is CancellationError {
            // stop() owns terminal signaling.
        } catch {
            if isCurrentReceiveGeneration(receiveGeneration) {
                await state.disconnect()

                // stop() may have retired this generation while state.disconnect()
                // was suspended on the state actor.
                if isCurrentReceiveGeneration(receiveGeneration) {
                    await failAll(error)
                    for continuation in eventContinuations.values {
                        continuation.finish(throwing: error)
                    }
                    eventContinuations.removeAll(keepingCapacity: false)
                }
            }
        }

        finishReceiveLoop(generation: receiveGeneration)
    }

    private func isCurrentReceiveGeneration(_ expected: UInt64) -> Bool {
        generation == expected && receiveTask?.generation == expected
    }

    private func finishReceiveLoop(generation completed: UInt64) {
        guard receiveTask?.generation == completed else { return }
        receiveTask = nil
    }

    private func isActiveRequestGeneration(_ expected: UInt64) -> Bool {
        !stopping &&
            generation == expected &&
            receiveTask?.generation == expected
    }

    private func markSendStarted(
        id: String,
        generation expected: UInt64
    ) -> Bool {
        guard isActiveRequestGeneration(expected),
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
        let terminalError: Error = mayHaveBeenSent
            ? OpenClawTransportSendError.deliveryUncertain
            : CancellationError()
        responses.removeValue(forKey: id)?.resume(
            throwing: terminalError
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
            let terminalError: Error = mayHaveBeenSent
                ? OpenClawTransportSendError.deliveryUncertain
                : error
            responses.removeValue(forKey: item.id)?.resume(
                throwing: terminalError
            )
        }
    }
}


public enum OpenClawRPCDispatcherError: Error, Sendable, Equatable {
    case deadlineExceeded
}
