import Foundation
import XCTest
@testable import AgentWearLinkOpenClaw

private actor DispatcherSocket: OpenClawWebSocket {
    private var inbound: [String] = []
    private var waiter: CheckedContinuation<String, Error>?
    private var sentFrames: [String] = []
    private let sentSignal = OpenClawTestCountSignal()
    private let receiveSignal = OpenClawTestCountSignal()
    private var generation: UInt64 = 1

    func connect() async {}

    func send(text: String) async throws {
        sentFrames.append(text)
        await sentSignal.increment()
    }

    func transportGeneration() async -> UInt64? { generation }

    func send(
        text: String,
        expectedGeneration: UInt64
    ) async throws {
        guard expectedGeneration == generation else {
            throw OpenClawTransportSendError.staleGeneration
        }
        sentFrames.append(text)
        await sentSignal.increment()
    }

    func receive() async throws -> String {
        let text: String
        if !inbound.isEmpty {
            text = inbound.removeFirst()
        } else {
            text = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { waiter = $0 }
            } onCancel: {
                Task { await self.cancelPendingReceive() }
            }
        }

        await receiveSignal.increment()
        return text
    }

    func waitUntilReceived(_ count: Int) async throws {
        try await receiveSignal.wait(
            until: count,
            label: "dispatcher socket received frame"
        )
    }

    private func cancelPendingReceive() {
        waiter?.resume(throwing: CancellationError())
        waiter = nil
    }

    func close() async {
        waiter?.resume(throwing: AWLOpenClawError.disconnected)
        waiter = nil
    }

    func push(_ text: String) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: text)
        } else {
            inbound.append(text)
        }
    }

    func sentCount() -> Int {
        sentFrames.count
    }

    func lastRequestID() async throws -> String {
        try await sentSignal.wait(
            until: 1,
            label: "dispatcher socket sent frame"
        )

        guard let text = sentFrames.last,
              let data = text.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String else {
            throw OpenClawFrameError.malformedFrame
        }
        return id
    }
}


private actor RegistrationGate {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func block() async {
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
            entered = true
            let waiters = enteredWaiters
            enteredWaiters.removeAll(keepingCapacity: false)
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func open() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor GenerationGateSocket: OpenClawWebSocket {
    private var generation: UInt64 = 1
    private var sendEntered = false
    private let sendEnteredSignal = OpenClawTestCountSignal()
    private var sendReleased = false
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private var receiveWaiter: CheckedContinuation<String, Error>?
    private var sentFrames: [String] = []

    func connect() async {}

    func transportGeneration() async -> UInt64? { generation }

    func send(text: String) async throws {
        sentFrames.append(text)
    }

    func send(
        text: String,
        expectedGeneration: UInt64
    ) async throws {
        sendEntered = true
        await sendEnteredSignal.increment()

        if !sendReleased {
            await withCheckedContinuation { continuation in
                releaseWaiter = continuation
            }
        }

        guard expectedGeneration == generation else {
            throw OpenClawTransportSendError.staleGeneration
        }

        // Deliberately record even if the caller task was cancelled. This models
        // a send already handed to the transport and lets the dispatcher prove
        // that cancellation after handoff is surfaced as delivery-uncertain.
        sentFrames.append(text)
    }

    func receive() async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                receiveWaiter = continuation
            }
        } onCancel: {
            Task { await self.cancelPendingReceive() }
        }
    }

    private func cancelPendingReceive() {
        receiveWaiter?.resume(throwing: CancellationError())
        receiveWaiter = nil
    }

    func close() async {
        receiveWaiter?.resume(throwing: AWLOpenClawError.disconnected)
        receiveWaiter = nil
    }

    func waitUntilSendEntered() async throws {
        try await sendEnteredSignal.wait(
            until: 1,
            label: "generation-gated send entry"
        )
    }

    func reconnect() {
        generation &+= 1
    }

    func releaseSend() {
        sendReleased = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }

    func sentCount() -> Int { sentFrames.count }
}


private actor DelayedRetirementSocket: OpenClawWebSocket {
    private var receiveCalls = 0
    private let receiveSignal = OpenClawTestCountSignal()
    private var receiveWaiters: [CheckedContinuation<String, Error>] = []

    func connect() async {}
    func send(text: String) async throws {}

    func receive() async throws -> String {
        receiveCalls += 1
        return try await withCheckedThrowingContinuation { continuation in
            receiveWaiters.append(continuation)
            Task { await self.signalReceiveEntry() }
        }
    }

    private func signalReceiveEntry() async {
        await receiveSignal.increment()
    }

    func close() async {}

    func waitUntilReceiveCount(_ count: Int) async throws {
        try await receiveSignal.wait(
            until: count,
            label: "delayed receiver count \(count)"
        )
    }

    func releaseOldestReceive() {
        guard !receiveWaiters.isEmpty else { return }
        let waiter = receiveWaiters.removeFirst()
        waiter.resume(throwing: AWLOpenClawError.disconnected)
    }

    func receiveCount() -> Int { receiveCalls }
}

final class OpenClawRPCDispatcherTests: XCTestCase {
    private func readyState(
        role: String = "operator",
        scopes: [String] = ["operator.read"],
        methods: [String] = ["health"],
        maxPayload: Int = 4_096,
        maxBufferedBytes: Int = 8_192
    ) async throws -> OpenClawGatewayState {
        let scopesData = try JSONSerialization.data(withJSONObject: scopes)
        let methodsData = try JSONSerialization.data(withJSONObject: methods)
        guard let scopesJSON = String(data: scopesData, encoding: .utf8),
              let methodsJSON = String(data: methodsData, encoding: .utf8) else {
            throw OpenClawFrameError.malformedFrame
        }

        let state = OpenClawGatewayState()
        let hello = try JSONDecoder().decode(
            OpenClawHelloOK.self,
            from: Data("""
            {
              "type":"hello-ok","protocol":4,
              "server":{"version":"x","connId":"c"},
              "features":{"methods":\(methodsJSON),"events":["tick"]},
              "auth":{"role":"\(role)","scopes":\(scopesJSON)},
              "policy":{"maxPayload":\(maxPayload),"maxBufferedBytes":\(maxBufferedBytes),"tickIntervalMs":15000}
            }
            """.utf8)
        )
        try await state.acceptHello(hello)
        return state
    }

    func testNativeOperationsRejectReducedGrantBeforeSocketSend() async throws {
        for method in ["agent", "agent.wait", "chat.abort"] {
            let socket = DispatcherSocket()
            let dispatcher = OpenClawRPCDispatcher(
                socket: socket,
                state: try await readyState(
                    scopes: ["operator.read"],
                    methods: []
                )
            )
            await dispatcher.start()

            do {
                _ = try await dispatcher.request(
                    method: method,
                    params: EmptyParams()
                )
                XCTFail("Expected authorization rejection for \(method)")
            } catch let error as OpenClawAuthorizationError {
                XCTAssertEqual(error, .missingScope("operator.write"))
            } catch {
                XCTFail("Unexpected error for \(method): \(error)")
            }

            let sentCount = await socket.sentCount()

            XCTAssertEqual(sentCount, 0)
            await dispatcher.stop()
            await socket.close()
        }
    }

    func testNativeOperationsRejectNonOperatorRoleBeforeSocketSend() async throws {
        let socket = DispatcherSocket()
        let dispatcher = OpenClawRPCDispatcher(
            socket: socket,
            state: try await readyState(
                role: "node",
                scopes: ["operator.write"],
                methods: []
            )
        )
        await dispatcher.start()

        do {
            _ = try await dispatcher.request(
                method: "agent",
                params: EmptyParams()
            )
            XCTFail("Expected role rejection")
        } catch let error as OpenClawAuthorizationError {
            XCTAssertEqual(
                error,
                .roleMismatch(expected: "operator", actual: "node")
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let sentCount = await socket.sentCount()

        XCTAssertEqual(sentCount, 0)
        await dispatcher.stop()
        await socket.close()
    }

    func testConservativeFeatureListDoesNotBlockAuthorizedNativeRoute() async throws {
        let socket = DispatcherSocket()
        let dispatcher = OpenClawRPCDispatcher(
            socket: socket,
            state: try await readyState(
                scopes: ["operator.write"],
                methods: []
            )
        )
        await dispatcher.start()

        let requestTask = Task {
            try await dispatcher.request(
                method: "agent",
                params: EmptyParams()
            )
        }

        let id = try await socket.lastRequestID()
        await socket.push(
            #"{"type":"res","id":"\#(id)","ok":true,"payload":{}}"#
        )

        _ = try await requestTask.value
        let sentCount = await socket.sentCount()
        XCTAssertEqual(sentCount, 1)
        await dispatcher.stop()
        await socket.close()
    }

    func testReconnectUsesFreshAuthorizationSnapshot() async throws {
        let socket = DispatcherSocket()
        let state = try await readyState(
            scopes: ["operator.write"],
            methods: []
        )
        let dispatcher = OpenClawRPCDispatcher(socket: socket, state: state)
        await dispatcher.start()

        let reducedState = try await readyState(
            scopes: ["operator.read"],
            methods: []
        )
        guard let reducedHello = await reducedState.hello else {
            XCTFail("Expected reduced hello")
            return
        }

        await state.beginReconnect(attempt: 1)
        try await state.acceptHello(reducedHello)

        do {
            _ = try await dispatcher.request(
                method: "agent.wait",
                params: EmptyParams()
            )
            XCTFail("Expected refreshed reduced grant rejection")
        } catch let error as OpenClawAuthorizationError {
            XCTAssertEqual(error, .missingScope("operator.write"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let sentCount = await socket.sentCount()

        XCTAssertEqual(sentCount, 0)
        await dispatcher.stop()
        await socket.close()
    }

    func testOversizedAgentTextIsRejectedBeforeSocketSend() async throws {
        let socket = DispatcherSocket()
        let dispatcher = OpenClawRPCDispatcher(
            socket: socket,
            state: try await readyState(
                scopes: ["operator.write"],
                methods: [],
                maxPayload: 32
            )
        )
        await dispatcher.start()

        do {
            _ = try await dispatcher.request(
                method: "agent",
                params: OpenClawAgentParams(
                    message: String(repeating: "x", count: 33),
                    idempotencyKey: "idempotency"
                )
            )
            XCTFail("Expected negotiated request limit rejection")
        } catch let error as AWLOpenClawError {
            XCTAssertEqual(error, .payloadTooLarge(actual: 33, maximum: 32))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let sentCount = await socket.sentCount()
        XCTAssertEqual(sentCount, 0)
        await dispatcher.stop()
        await socket.close()
    }

    func testCorrelatesRPCResponse() async throws {
        let socket = DispatcherSocket()
        let dispatcher = OpenClawRPCDispatcher(
            socket: socket,
            state: try await readyState()
        )
        await dispatcher.start()

        let requestTask = Task {
            try await dispatcher.request(
                method: "health",
                params: EmptyParams()
            )
        }

        let id = try await socket.lastRequestID()
        await socket.push(
            #"{"type":"res","id":"\#(id)","ok":true,"payload":{"status":"ok"}}"#
        )

        let response = try await requestTask.value
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.id, id)
        await dispatcher.stop()
    }


    func testRequestDeadlineFailsAndCleansRegistry() async throws {
        let socket = DispatcherSocket()
        let registry = OpenClawRPCRegistry()
        let dispatcher = OpenClawRPCDispatcher(
            socket: socket,
            state: try await readyState(),
            registry: registry,
            requestTimeout: .milliseconds(20)
        )
        await dispatcher.start()

        do {
            _ = try await dispatcher.request(
                method: "health",
                params: EmptyParams()
            )
            XCTFail("Expected RPC deadline")
        } catch let error as OpenClawRPCDispatcherError {
            XCTAssertEqual(error, .deadlineExceeded)
        }

        let count = await registry.count
        XCTAssertEqual(count, 0)
        await dispatcher.stop()
        await socket.close()
    }


    func testLivenessUsesTwoIntervalThresholdWithoutHotLooping() async throws {
        let socket = DispatcherSocket()
        let dispatcher = OpenClawRPCDispatcher(
            socket: socket,
            state: try await readyState(),
            nowMilliseconds: { 1_000 }
        )

        await dispatcher.start()

        let atBoundary = await dispatcher.isStale(
            timeoutMilliseconds: 2_000,
            now: 3_000
        )
        let pastBoundary = await dispatcher.isStale(
            timeoutMilliseconds: 2_000,
            now: 3_001
        )

        XCTAssertFalse(atBoundary)
        XCTAssertTrue(pastBoundary)
        await dispatcher.stop()
        await socket.close()
    }

    func testPendingAgentBufferEnforcesNegotiatedByteBudget() async throws {
        let first = #"{"type":"event","event":"agent","payload":{"runId":"r","stream":"assistant","data":{"delta":"one"},"seq":1},"seq":1}"#
        let second = #"{"type":"event","event":"agent","payload":{"runId":"r","stream":"assistant","data":{"delta":"two"},"seq":2},"seq":2}"#
        let totalBytes = first.utf8.count + second.utf8.count
        let maximumBufferedBytes = totalBytes - 1

        let socket = DispatcherSocket()
        let state = try await readyState(maxBufferedBytes: maximumBufferedBytes)
        let dispatcher = OpenClawRPCDispatcher(socket: socket, state: state)
        let events = await dispatcher.events()
        await dispatcher.start()

        let terminalErrorTask = Task { () -> AWLOpenClawError? in
            do {
                for try await _ in events {}
                return nil
            } catch let error as AWLOpenClawError {
                return error
            } catch {
                return nil
            }
        }

        await socket.push(first)
        await socket.push(second)

        try await waitUntilOpenClawTestCondition(
            "pending buffer budget retired transport"
        ) {
            await state.connectionState == .disconnected
        }

        let terminalError = await terminalErrorTask.value
        XCTAssertEqual(
            terminalError,
            .bufferBudgetExceeded(
                actual: totalBytes,
                maximum: maximumBufferedBytes
            )
        )
        let running = await dispatcher.isRunning
        XCTAssertFalse(running)
        await dispatcher.stop()
        await socket.close()
    }

    func testPendingAgentBufferUsesFreshReconnectBudget() async throws {
        let first = #"{"type":"event","event":"agent","payload":{"runId":"r","stream":"assistant","data":{"delta":"one"},"seq":1},"seq":1}"#
        let second = #"{"type":"event","event":"agent","payload":{"runId":"r","stream":"assistant","data":{"delta":"two"},"seq":2},"seq":2}"#
        let totalBytes = first.utf8.count + second.utf8.count

        let socket = DispatcherSocket()
        let state = try await readyState(maxBufferedBytes: first.utf8.count)
        let dispatcher = OpenClawRPCDispatcher(socket: socket, state: state)
        await dispatcher.start()

        let refreshed = try await readyState(maxBufferedBytes: totalBytes)
        guard let refreshedHello = await refreshed.hello else {
            XCTFail("Expected refreshed hello")
            return
        }
        await state.beginReconnect(attempt: 1)
        try await state.acceptHello(refreshedHello)

        let observedEvents = await dispatcher.events()
        let observedTwoEvents = Task {
            var iterator = observedEvents.makeAsyncIterator()
            _ = try await iterator.next()
            _ = try await iterator.next()
        }

        await socket.push(first)
        await socket.push(second)
        try await observedTwoEvents.value

        let stream = await dispatcher.agentEvents(runID: "r")
        var iterator = stream.makeAsyncIterator()
        let firstBuffered = try await iterator.next()
        let secondBuffered = try await iterator.next()

        XCTAssertEqual(firstBuffered?.seq, 1)
        XCTAssertEqual(secondBuffered?.seq, 2)
        let currentState = await state.connectionState
        XCTAssertEqual(currentState, .ready)

        await dispatcher.stop()
        await socket.close()
    }

    func testBroadcastsEventsToConcurrentSubscribers() async throws {
        let socket = DispatcherSocket()
        let dispatcher = OpenClawRPCDispatcher(
            socket: socket,
            state: try await readyState()
        )
        let first = await dispatcher.events()
        let second = await dispatcher.events()
        await dispatcher.start()

        let firstTask = Task {
            for try await event in first { return event }
            throw AWLOpenClawError.disconnected
        }
        let secondTask = Task {
            for try await event in second { return event }
            throw AWLOpenClawError.disconnected
        }

        await socket.push(
            #"{"type":"event","event":"agent","payload":{"runId":"r"},"seq":1}"#
        )

        let firstEvent = try await firstTask.value
        let secondEvent = try await secondTask.value
        XCTAssertEqual(firstEvent.seq, 1)
        XCTAssertEqual(secondEvent.seq, 1)

        await dispatcher.stop()
        await socket.close()
    }

    func testGenericEventSubscriberFailsOnBoundedBufferOverflow() async throws {
        let socket = DispatcherSocket()
        let dispatcher = OpenClawRPCDispatcher(
            socket: socket,
            state: try await readyState(),
            eventBufferLimit: 2
        )
        let events = await dispatcher.events()
        await dispatcher.start()

        for sequence in 1...4 {
            await socket.push(
                #"{"type":"event","event":"tick","payload":{},"seq":\#(sequence)}"#
            )
        }

        // Waiting for the fourth receive proves the third event has already
        // been routed, which deterministically overflows the 2-event subscriber.
        try await socket.waitUntilReceived(4)

        var iterator = events.makeAsyncIterator()
        let second = try await iterator.next()
        let third = try await iterator.next()
        XCTAssertEqual(second?.seq, 2)
        XCTAssertEqual(third?.seq, 3)

        do {
            _ = try await iterator.next()
            XCTFail("Expected bounded generic event subscriber overflow")
        } catch let error as OpenClawEventRoutingError {
            XCTAssertEqual(error, .bufferOverflow)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // A slow generic subscriber is isolated; it must not retire transport.
        let running = await dispatcher.isRunning
        XCTAssertTrue(running)
        await dispatcher.stop()
        await socket.close()
    }

    func testRoutesEventsIndependentlyOfRPCs() async throws {
        let socket = DispatcherSocket()
        let dispatcher = OpenClawRPCDispatcher(
            socket: socket,
            state: try await readyState()
        )
        let events = await dispatcher.events()
        await dispatcher.start()

        let eventTask = Task {
            for try await event in events { return event }
            throw AWLOpenClawError.disconnected
        }

        await socket.push(
            #"{"type":"event","event":"tick","payload":{},"seq":1}"#
        )

        let event = try await eventTask.value
        XCTAssertEqual(event.event, "tick")
        XCTAssertEqual(event.seq, 1)
        await dispatcher.stop()
    }
    func testRetiredGenerationCannotGhostSendAfterReconnect() async throws {
        let socket = GenerationGateSocket()
        let dispatcher = OpenClawRPCDispatcher(
            socket: socket,
            state: try await readyState()
        )
        await dispatcher.start()

        let requestTask = Task {
            try await dispatcher.request(
                method: "mutate",
                params: EmptyParams()
            )
        }

        try await socket.waitUntilSendEntered()

        let stopTask = Task {
            await dispatcher.stop()
        }
        try await waitUntilOpenClawTestCondition(
            "dispatcher entered stop"
        ) {
            !(await dispatcher.isRunning)
        }

        // Reuse the same socket object for a new transport generation before the
        // delayed old-generation send is allowed to enter its critical section.
        await socket.reconnect()
        await socket.releaseSend()
        await stopTask.value

        do {
            _ = try await requestTask.value
            XCTFail("Expected the retired generation to reject the send")
        } catch let error as OpenClawTransportSendError {
            XCTAssertEqual(error, .staleGeneration)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let sentCount = await socket.sentCount()
        XCTAssertEqual(sentCount, 0)
    }

    func testStopAfterSendHandoffReportsDeliveryUncertain() async throws {
        let socket = GenerationGateSocket()
        let dispatcher = OpenClawRPCDispatcher(
            socket: socket,
            state: try await readyState()
        )
        await dispatcher.start()

        let requestTask = Task {
            try await dispatcher.request(
                method: "mutate",
                params: EmptyParams()
            )
        }

        try await socket.waitUntilSendEntered()

        let stopTask = Task {
            await dispatcher.stop()
        }
        try await waitUntilOpenClawTestCondition(
            "dispatcher entered stop"
        ) {
            !(await dispatcher.isRunning)
        }

        // No generation change: releasing the gate models a frame that reached
        // the old transport before stop could classify the pending RPC.
        await socket.releaseSend()
        await stopTask.value

        do {
            _ = try await requestTask.value
            XCTFail("Expected uncertain delivery after send handoff")
        } catch let error as OpenClawTransportSendError {
            XCTAssertEqual(error, .deliveryUncertain)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let sentCount = await socket.sentCount()
        XCTAssertEqual(sentCount, 1)
    }

    func testStopDuringRegistryRegistrationCannotResurrectRequest() async throws {
        let socket = GenerationGateSocket()
        let registrationGate = RegistrationGate()
        let registry = OpenClawRPCRegistry(
            beforeRegister: {
                await registrationGate.block()
            }
        )
        let dispatcher = OpenClawRPCDispatcher(
            socket: socket,
            state: try await readyState(),
            registry: registry
        )
        await dispatcher.start()

        let requestTask = Task {
            try await dispatcher.request(
                method: "mutate",
                params: EmptyParams()
            )
        }

        await registrationGate.waitUntilEntered()
        await dispatcher.stop()
        await registrationGate.open()

        do {
            _ = try await requestTask.value
            XCTFail("Expected retired registration to fail")
        } catch let error as AWLOpenClawError {
            XCTAssertEqual(error, .disconnected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let pendingCount = await registry.count
        let sentCount = await socket.sentCount()
        XCTAssertEqual(pendingCount, 0)
        XCTAssertEqual(sentCount, 0)
        await socket.close()
    }


    func testStopOwnsDelayedReceiverUntilItActuallyExits() async throws {
        let socket = DelayedRetirementSocket()
        let dispatcher = OpenClawRPCDispatcher(
            socket: socket,
            state: try await readyState()
        )

        await dispatcher.start()
        try await socket.waitUntilReceiveCount(1)

        let stopTask = Task {
            await dispatcher.stop()
        }
        try await waitUntilOpenClawTestCondition(
            "dispatcher entered stop"
        ) {
            !(await dispatcher.isRunning)
        }

        // A restart attempt while stop() still owns the old reader must be ignored.
        await dispatcher.start()
        let countWhileStopping = await socket.receiveCount()
        XCTAssertEqual(countWhileStopping, 1)

        await socket.releaseOldestReceive()
        await stopTask.value

        let runningAfterStop = await dispatcher.isRunning
        XCTAssertFalse(runningAfterStop)

        // A new reader is admitted only after the prior one has actually exited.
        await dispatcher.start()
        try await socket.waitUntilReceiveCount(2)
        let countAfterRestart = await socket.receiveCount()
        XCTAssertEqual(countAfterRestart, 2)

        let finalStop = Task {
            await dispatcher.stop()
        }
        try await waitUntilOpenClawTestCondition(
            "dispatcher entered final stop"
        ) {
            !(await dispatcher.isRunning)
        }
        await socket.releaseOldestReceive()
        await finalStop.value

        let finalRunning = await dispatcher.isRunning
        XCTAssertFalse(finalRunning)
    }


    func testGatewaySequenceGapRetiresCurrentReceiveGeneration() async throws {
        let socket = DispatcherSocket()
        let state = try await readyState()
        let dispatcher = OpenClawRPCDispatcher(
            socket: socket,
            state: state
        )
        let events = await dispatcher.events()
        await dispatcher.start()

        await socket.push(
            #"{"type":"event","event":"tick","payload":{},"seq":1}"#
        )
        await socket.push(
            #"{"type":"event","event":"tick","payload":{},"seq":3}"#
        )
        try await socket.waitUntilReceived(2)

        var iterator = events.makeAsyncIterator()
        let first = try await iterator.next()
        XCTAssertEqual(first?.seq, 1)

        do {
            _ = try await iterator.next()
            XCTFail("Expected sequence-gap retirement")
        } catch let error as AWLOpenClawError {
            XCTAssertEqual(
                error,
                .sequenceGap(expected: 2, actual: 3)
            )
        }

        try await waitUntilOpenClawTestCondition(
            "sequence gap retired dispatcher generation"
        ) {
            await state.connectionState == .disconnected
        }
        let running = await dispatcher.isRunning
        XCTAssertFalse(running)

        await dispatcher.stop()
        await socket.close()
    }


    func testDropsDuplicateAndStaleRunLocalAgentSequences() async throws {
        let socket = DispatcherSocket()
        let dispatcher = OpenClawRPCDispatcher(
            socket: socket,
            state: try await readyState()
        )
        let runEvents = await dispatcher.agentEvents(runID: "run-seq")
        let genericEvents = await dispatcher.events()
        await dispatcher.start()

        let observeFourFrames = Task {
            var iterator = genericEvents.makeAsyncIterator()
            for _ in 0..<4 {
                _ = try await iterator.next()
            }
        }

        await socket.push(
            #"{"type":"event","event":"agent","payload":{"runId":"run-seq","stream":"assistant","data":{"delta":"one"},"seq":1},"seq":1}"#
        )
        await socket.push(
            #"{"type":"event","event":"agent","payload":{"runId":"run-seq","stream":"assistant","data":{"delta":"duplicate"},"seq":1},"seq":2}"#
        )
        await socket.push(
            #"{"type":"event","event":"agent","payload":{"runId":"run-seq","stream":"assistant","data":{"delta":"stale"},"seq":0},"seq":3}"#
        )
        await socket.push(
            #"{"type":"event","event":"agent","payload":{"runId":"run-seq","stream":"assistant","data":{"delta":"two"},"seq":2},"seq":4}"#
        )

        try await observeFourFrames.value
        await dispatcher.finishAgentEvents(runID: "run-seq")

        var iterator = runEvents.makeAsyncIterator()
        let first = try await iterator.next()
        let second = try await iterator.next()
        let end = try await iterator.next()

        XCTAssertEqual(first?.seq, 1)
        XCTAssertEqual(second?.seq, 2)
        XCTAssertNil(end)

        await dispatcher.stop()
        await socket.close()
    }


}

private struct EmptyParams: Encodable, Sendable {}
