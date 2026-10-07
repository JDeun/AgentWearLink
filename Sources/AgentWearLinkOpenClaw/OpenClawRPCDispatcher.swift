import Foundation

public actor OpenClawRPCDispatcher {
    public static let defaultAgentEventBufferLimit = 64
    public static let defaultPendingAgentEventLimit = 128

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

    private var receiveTask: ReceiveTaskEntry?
    private var requestTasks: [String: Task<Void, Never>] = [:]
    private var sendStarted: Set<String> = []
    private var generation: UInt64 = 0
    private var stopping = false
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
        let subscriberGeneration = receiveTask?.generation ?? (generation &+ 1)
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
                rememberFinishedAgentRun(runID)
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
        guard !stopping, receiveTask == nil else { return }
        generation &+= 1
        let receiveGeneration = generation
        lastActivityMilliseconds = nowMilliseconds()
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.receiveLoop(generation: receiveGeneration)
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

        // Preserve the retiring receive-task handle until that exact reader exits.
        // start() remains fenced while stop() is suspended here, guaranteeing that
        // one physical socket never has two concurrent dispatcher readers.
        if let retiringReceiveTask {
            await retiringReceiveTask.task.value
        }

        await failAll(AWLOpenClawError.disconnected)
        for continuation in eventContinuations.values {
            continuation.finish()
        }
        eventContinuations.removeAll(keepingCapacity: false)
        finishAllAgentEventSubscribers()
        resetAgentRoutingBuffers()
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

                    // A response that resolves the old registry wins its race with
                    // stop(). stop() cannot install a newer reader until this loop
                    // has actually returned.
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
                    if let agentEvent = Self.decodeAgentEvent(event) {
                        routeAgentEvent(
                            agentEvent,
                            generation: receiveGeneration
                        )
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

                if isCurrentReceiveGeneration(receiveGeneration) {
                    await failAll(error)
                    for continuation in eventContinuations.values {
                        continuation.finish(throwing: error)
                    }
                    eventContinuations.removeAll(keepingCapacity: false)
                    finishAllAgentEventSubscribers(throwing: error)
                    resetAgentRoutingBuffers()
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

    private func isActive(generation expected: UInt64) -> Bool {
        !stopping &&
            generation == expected &&
            receiveTask?.generation == expected
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
        case let .some(.number(value)):
            let integer = Int(value)
            seq = Double(integer) == value ? integer : nil
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

    private func routeAgentEvent(
        _ event: OpenClawAgentEvent,
        generation receiveGeneration: UInt64
    ) {
        let runID = event.runId
        guard !finishedAgentRunIDs.contains(runID),
              !pendingAgentOverflowRunIDs.contains(runID) else {
            return
        }

        if var subscribers = agentEventContinuations[runID],
           !subscribers.isEmpty {
            var delivered = false
            var overflowed = false

            for (id, subscriber) in subscribers {
                guard subscriber.generation == receiveGeneration else {
                    subscriber.continuation.finish()
                    subscribers[id] = nil
                    continue
                }

                switch subscriber.continuation.yield(event) {
                case .enqueued:
                    delivered = true
                case .dropped:
                    delivered = true
                    overflowed = true
                case .terminated:
                    subscribers[id] = nil
                @unknown default:
                    subscribers[id] = nil
                }
            }

            if subscribers.isEmpty {
                agentEventContinuations[runID] = nil
            } else {
                agentEventContinuations[runID] = subscribers
            }

            if overflowed {
                failAgentRunSubscribers(
                    runID: runID,
                    error: OpenClawAgentEventRoutingError.bufferOverflow(runID)
                )
                return
            }
            if delivered {
                return
            }
        }

        bufferPendingAgentEvent(event)
    }

    private func bufferPendingAgentEvent(_ event: OpenClawAgentEvent) {
        let runID = event.runId
        guard !pendingAgentOverflowRunIDs.contains(runID),
              !finishedAgentRunIDs.contains(runID) else {
            return
        }

        if pendingAgentEvents.count >= pendingAgentEventLimit {
            let dropped = pendingAgentEvents.removeFirst()
            rememberPendingAgentOverflow(dropped.runId)
        }

        guard !pendingAgentOverflowRunIDs.contains(runID),
              !finishedAgentRunIDs.contains(runID) else {
            return
        }
        pendingAgentEvents.append(event)
    }

    private func removeAgentEventSubscriber(
        runID: String,
        id: UUID,
        generation expectedGeneration: UInt64
    ) {
        guard var subscribers = agentEventContinuations[runID],
              let subscriber = subscribers[id],
              subscriber.generation == expectedGeneration else {
            return
        }

        subscribers[id] = nil
        if subscribers.isEmpty {
            agentEventContinuations[runID] = nil
        } else {
            agentEventContinuations[runID] = subscribers
        }
    }

    private func failAgentRunSubscribers(
        runID: String,
        error: Error
    ) {
        if let subscribers = agentEventContinuations.removeValue(forKey: runID) {
            for subscriber in subscribers.values {
                subscriber.continuation.finish(throwing: error)
            }
        }
        pendingAgentEvents.removeAll { $0.runId == runID }
        pendingAgentOverflowRunIDs.remove(runID)
        pendingAgentOverflowOrder.removeAll { $0 == runID }
        rememberFinishedAgentRun(runID)
    }

    private func finishAllAgentEventSubscribers(
        throwing error: Error? = nil
    ) {
        let allSubscribers = agentEventContinuations.values.flatMap { $0.values }
        agentEventContinuations.removeAll(keepingCapacity: false)

        for subscriber in allSubscribers {
            if let error {
                subscriber.continuation.finish(throwing: error)
            } else {
                subscriber.continuation.finish()
            }
        }
    }

    private func rememberPendingAgentOverflow(_ runID: String) {
        pendingAgentEvents.removeAll { $0.runId == runID }
        guard pendingAgentOverflowRunIDs.insert(runID).inserted else { return }
        pendingAgentOverflowOrder.append(runID)

        while pendingAgentOverflowOrder.count > pendingAgentEventLimit {
            let evicted = pendingAgentOverflowOrder.removeFirst()
            pendingAgentOverflowRunIDs.remove(evicted)
        }
    }

    private func rememberFinishedAgentRun(_ runID: String) {
        guard finishedAgentRunIDs.insert(runID).inserted else { return }
        finishedAgentRunOrder.append(runID)

        while finishedAgentRunOrder.count > pendingAgentEventLimit {
            let evicted = finishedAgentRunOrder.removeFirst()
            finishedAgentRunIDs.remove(evicted)
        }
    }

    private func resetAgentRoutingBuffers() {
        pendingAgentEvents.removeAll(keepingCapacity: false)
        pendingAgentOverflowRunIDs.removeAll(keepingCapacity: false)
        pendingAgentOverflowOrder.removeAll(keepingCapacity: false)
        finishedAgentRunIDs.removeAll(keepingCapacity: false)
        finishedAgentRunOrder.removeAll(keepingCapacity: false)
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
