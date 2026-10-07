import Foundation

public actor OpenClawRPCDispatcher {
    public static let defaultAgentEventBufferLimit = 64
    public static let defaultPendingAgentEventLimit = 128

    private let socket: any OpenClawWebSocket
    private let state: OpenClawGatewayState
    private let registry: OpenClawRPCRegistry
    private let router = OpenClawFrameRouter()
    private let encoder = JSONEncoder()

    private var responses: [String: CheckedContinuation<OpenClawResponseEnvelope, Error>] = [:]
    private var eventContinuations: [
        UUID: AsyncThrowingStream<OpenClawEventEnvelope, Error>.Continuation
    ] = [:]

    private struct AgentEventSubscriber {
        let generation: UInt64
        let continuation: AsyncThrowingStream<OpenClawAgentEvent, Error>.Continuation
    }

    private var agentEventContinuations: [
        String: [UUID: AgentEventSubscriber]
    ] = [:]
    private var pendingAgentEvents: [OpenClawAgentEvent] = []
    private var pendingAgentOverflowRunIDs: Set<String> = []
    private var pendingAgentOverflowOrder: [String] = []
    private var finishedAgentRunIDs: Set<String> = []
    private var finishedAgentRunOrder: [String] = []

    private var receiveTask: Task<Void, Never>?
    private var requestTasks: [String: Task<Void, Never>] = [:]
    private var sendStarted: Set<String> = []
    private var generation: UInt64 = 0
    private var lastActivityMilliseconds: Int64?
    private let nowMilliseconds: @Sendable () -> Int64
    private let requestTimeout: Duration
    private let inboundMaximumBytes: Int
    private let agentEventBufferLimit: Int
    private let pendingAgentEventLimit: Int

    public init(
        socket: any OpenClawWebSocket,
        state: OpenClawGatewayState,
        registry: OpenClawRPCRegistry = .init(),
        requestTimeout: Duration = .seconds(30),
        inboundMaximumBytes: Int = OpenClawFrameRouter.defaultInboundMaximumBytes,
        agentEventBufferLimit: Int = OpenClawRPCDispatcher.defaultAgentEventBufferLimit,
        pendingAgentEventLimit: Int = OpenClawRPCDispatcher.defaultPendingAgentEventLimit,
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
        precondition(agentEventBufferLimit > 0)
        self.agentEventBufferLimit = agentEventBufferLimit
        precondition(pendingAgentEventLimit > 0)
        self.pendingAgentEventLimit = pendingAgentEventLimit
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

    public func agentEvents(
        runID: String
    ) -> AsyncThrowingStream<OpenClawAgentEvent, Error> {
        precondition(!runID.isEmpty)

        let id = UUID()
        let subscriberGeneration = receiveTask == nil ? generation &+ 1 : generation
        let bufferLimit = agentEventBufferLimit

        return AsyncThrowingStream(
            bufferingPolicy: .bufferingOldest(bufferLimit)
        ) { continuation in
            continuation.onTermination = { [weak self] _ in
                Task {
                    await self?.removeAgentEventSubscriber(
                        runID: runID,
                        id: id,
                        generation: subscriberGeneration
                    )
                }
            }

            guard !finishedAgentRunIDs.contains(runID) else {
                continuation.finish()
                return
            }

            if pendingAgentOverflowRunIDs.remove(runID) != nil {
                pendingAgentOverflowOrder.removeAll { $0 == runID }
                pendingAgentEvents.removeAll { $0.runId == runID }
                continuation.finish(
                    throwing: OpenClawAgentEventRoutingError.pendingBufferOverflow(runID)
                )
                return
            }

            agentEventContinuations[runID, default: [:]][id] = AgentEventSubscriber(
                generation: subscriberGeneration,
                continuation: continuation
            )

            let buffered = pendingAgentEvents.filter { $0.runId == runID }
            pendingAgentEvents.removeAll { $0.runId == runID }

            for event in buffered {
                if case .dropped = continuation.yield(event) {
                    failAgentRunSubscribers(
                        runID: runID,
                        error: OpenClawAgentEventRoutingError.bufferOverflow(runID)
                    )
                    return
                }
            }
        }
    }

    public func finishAgentEvents(runID: String) {
        if let subscribers = agentEventContinuations.removeValue(forKey: runID) {
            for subscriber in subscribers.values {
                subscriber.continuation.finish()
            }
        }
        pendingAgentEvents.removeAll { $0.runId == runID }
        pendingAgentOverflowRunIDs.remove(runID)
        pendingAgentOverflowOrder.removeAll { $0 == runID }
        rememberFinishedAgentRun(runID)
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
            throw AWLOpenClawError.notReady
        }
        let requestGeneration = generation

        guard await state.connectionState == .ready else {
            throw AWLOpenClawError.notReady
        }
        guard isActive(generation: requestGeneration) else {
            throw AWLOpenClawError.disconnected
        }

        // Capture transport identity while this dispatcher generation is active.
        // Every actor hop below is followed by a generation check so stop() cannot
        // retire the request and let it resume into a later dispatcher generation.
        let capturedTransportGeneration = await socket.transportGeneration()
        guard isActive(generation: requestGeneration) else {
            throw AWLOpenClawError.disconnected
        }
        guard let transportGeneration = capturedTransportGeneration else {
            throw OpenClawTransportSendError.generationBindingUnavailable
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

        try await registry.register(id: id, method: method)
        guard isActive(generation: requestGeneration) else {
            // register() is a separate actor hop. stop() may have drained the old
            // registry while this call was suspended and registration may complete
            // afterward; remove that late insertion before returning.
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
        finishAllAgentEventSubscribers()
        resetAgentRoutingBuffers()
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
                    if let agentEvent = Self.decodeAgentEvent(event) {
                        routeAgentEvent(agentEvent)
                    }
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
            finishAllAgentEventSubscribers(throwing: error)
            resetAgentRoutingBuffers()
        }
        receiveTask = nil
    }

    private static func decodeAgentEvent(
        _ envelope: OpenClawEventEnvelope
    ) -> OpenClawAgentEvent? {
        guard envelope.event == "agent",
              case let .object(object)? = envelope.payload,
              case let .string(runID)? = object["runId"],
              case let .string(stream)? = object["stream"] else {
            return nil
        }

        let seq: Int?
        switch object["seq"] {
        case let .some(.integer(value)):
            seq = Int(exactly: value)
        case let .some(.unsignedInteger(value)):
            seq = Int(exactly: value)
        default:
            seq = nil
        }

        let data: JSONValue?
        if case .some(.null) = object["data"] {
            data = nil
        } else {
            data = object["data"]
        }

        return OpenClawAgentEvent(
            runId: runID,
            stream: stream,
            data: data,
            seq: seq
        )
    }

    private func routeAgentEvent(_ event: OpenClawAgentEvent) {
        guard !finishedAgentRunIDs.contains(event.runId),
              !pendingAgentOverflowRunIDs.contains(event.runId) else {
            return
        }

        guard let subscribers = agentEventContinuations[event.runId],
              subscribers.values.contains(where: { $0.generation == generation }) else {
            bufferPendingAgentEvent(event)
            return
        }

        var terminated: [UUID] = []
        var overflowed = false

        for (id, subscriber) in subscribers {
            guard subscriber.generation == generation else {
                terminated.append(id)
                continue
            }

            switch subscriber.continuation.yield(event) {
            case .enqueued:
                break
            case .dropped:
                overflowed = true
            case .terminated:
                terminated.append(id)
            @unknown default:
                terminated.append(id)
            }
        }

        if overflowed {
            failAgentRunSubscribers(
                runID: event.runId,
                error: OpenClawAgentEventRoutingError.bufferOverflow(event.runId)
            )
            recordPendingAgentOverflow(event.runId)
            return
        }

        for id in terminated {
            agentEventContinuations[event.runId]?[id] = nil
        }
        if agentEventContinuations[event.runId]?.isEmpty == true {
            agentEventContinuations[event.runId] = nil
        }
    }

    private func bufferPendingAgentEvent(_ event: OpenClawAgentEvent) {
        if pendingAgentEvents.count >= pendingAgentEventLimit {
            let dropped = pendingAgentEvents.removeFirst()
            recordPendingAgentOverflow(dropped.runId)
        }

        guard !pendingAgentOverflowRunIDs.contains(event.runId),
              !finishedAgentRunIDs.contains(event.runId) else {
            return
        }
        pendingAgentEvents.append(event)
    }

    private func recordPendingAgentOverflow(_ runID: String) {
        pendingAgentEvents.removeAll { $0.runId == runID }
        guard pendingAgentOverflowRunIDs.insert(runID).inserted else { return }

        pendingAgentOverflowOrder.append(runID)
        if pendingAgentOverflowOrder.count > pendingAgentEventLimit {
            let evicted = pendingAgentOverflowOrder.removeFirst()
            pendingAgentOverflowRunIDs.remove(evicted)
        }
    }

    private func rememberFinishedAgentRun(_ runID: String) {
        guard finishedAgentRunIDs.insert(runID).inserted else { return }

        finishedAgentRunOrder.append(runID)
        if finishedAgentRunOrder.count > pendingAgentEventLimit {
            let evicted = finishedAgentRunOrder.removeFirst()
            finishedAgentRunIDs.remove(evicted)
        }
    }

    private func failAgentRunSubscribers(
        runID: String,
        error: Error
    ) {
        guard let subscribers = agentEventContinuations.removeValue(forKey: runID) else {
            return
        }
        for subscriber in subscribers.values {
            subscriber.continuation.finish(throwing: error)
        }
    }

    private func finishAllAgentEventSubscribers(
        throwing error: Error? = nil
    ) {
        let subscribers = agentEventContinuations.values.flatMap { $0.values }
        agentEventContinuations.removeAll(keepingCapacity: false)

        for subscriber in subscribers {
            if let error {
                subscriber.continuation.finish(throwing: error)
            } else {
                subscriber.continuation.finish()
            }
        }
    }

    private func resetAgentRoutingBuffers() {
        pendingAgentEvents.removeAll(keepingCapacity: false)
        pendingAgentOverflowRunIDs.removeAll(keepingCapacity: false)
        pendingAgentOverflowOrder.removeAll(keepingCapacity: false)
        finishedAgentRunIDs.removeAll(keepingCapacity: false)
        finishedAgentRunOrder.removeAll(keepingCapacity: false)
    }

    private func removeAgentEventSubscriber(
        runID: String,
        id: UUID,
        generation expectedGeneration: UInt64
    ) {
        guard let subscriber = agentEventContinuations[runID]?[id],
              subscriber.generation == expectedGeneration else {
            return
        }
        agentEventContinuations[runID]?[id] = nil
        if agentEventContinuations[runID]?.isEmpty == true {
            agentEventContinuations[runID] = nil
        }
    }

    private func isActive(generation expected: UInt64) -> Bool {
        generation == expected && receiveTask != nil
    }

    private func markSendStarted(
        id: String,
        generation expected: UInt64
    ) -> Bool {
        guard isActive(generation: expected),
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

public enum OpenClawAgentEventRoutingError: Error, Sendable, Equatable {
    case bufferOverflow(String)
    case pendingBufferOverflow(String)
}
