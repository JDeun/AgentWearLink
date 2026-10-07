import Foundation
import XCTest
@testable import AgentWearLinkOpenClaw

private actor DispatcherSocket: OpenClawWebSocket {
    private var inbound: [String] = []
    private var waiter: CheckedContinuation<String, Error>?
    private var sentFrames: [String] = []

    func connect() async {}

    func send(text: String) async throws {
        sentFrames.append(text)
    }

    func receive() async throws -> String {
        if !inbound.isEmpty { return inbound.removeFirst() }
        return try await withCheckedThrowingContinuation { waiter = $0 }
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
        while sentFrames.isEmpty {
            await Task.yield()
        }

        guard let text = sentFrames.last,
              let data = text.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String else {
            throw OpenClawFrameError.malformedFrame
        }
        return id
    }
}

private actor AsyncGate {
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
    private let gate: AsyncGate
    private var connected = false
    private var generation: UInt64 = 0
    private var sentGenerations: [UInt64] = []

    init(gate: AsyncGate) {
        self.gate = gate
    }

    func connect() async {
        guard !connected else { return }
        generation &+= 1
        connected = true
    }

    func currentConnectionGeneration() async -> UInt64 {
        generation
    }

    func send(text: String) async throws {
        guard connected else { throw AWLOpenClawError.disconnected }
        sentGenerations.append(generation)
    }

    func send(
        text: String,
        connectionGeneration expectedGeneration: UInt64
    ) async throws {
        await gate.block()
        try Task.checkCancellation()
        guard connected,
              generation == expectedGeneration else {
            throw AWLOpenClawError.disconnected
        }
        sentGenerations.append(generation)
    }

    func receive() async throws -> String {
        try await Task.sleep(for: .seconds(60))
        throw AWLOpenClawError.disconnected
    }

    func close() async {
        connected = false
    }

    func sentCount() -> Int {
        sentGenerations.count
    }
}

final class OpenClawRPCDispatcherTests: XCTestCase {
    private func readyState() async throws -> OpenClawGatewayState {
        let state = OpenClawGatewayState()
        let hello = try JSONDecoder().decode(
            OpenClawHelloOK.self,
            from: Data(#"""
            {
              "type":"hello-ok","protocol":4,
              "server":{"version":"x","connId":"c"},
              "features":{"methods":["health"],"events":["tick"]},
              "auth":{"role":"operator","scopes":["operator.read"]},
              "policy":{"maxPayload":4096,"maxBufferedBytes":8192,"tickIntervalMs":15000}
            }
            """#.utf8)
        )
        try await state.acceptHello(hello)
        return state
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

    func testStopDuringRegistryRegistrationCannotResurrectRequest() async throws {
        let socket = DispatcherSocket()
        let registrationGate = AsyncGate()
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
                method: "health",
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
        }

        XCTAssertEqual(await registry.count, 0)
        XCTAssertEqual(await socket.sentCount(), 0)
        await socket.close()
    }

    func testStopBeforeBlockedSendCannotGhostSendAfterReconnect() async throws {
        let gate = AsyncGate()
        let socket = GenerationGateSocket(gate: gate)
        await socket.connect()

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

        await gate.waitUntilEntered()

        let stopTask = Task {
            await dispatcher.stop()
        }
        await Task.yield()

        await socket.close()
        await socket.connect()
        await gate.open()
        await stopTask.value

        do {
            _ = try await requestTask.value
            XCTFail("Expected retired request to fail")
        } catch let error as AWLOpenClawError {
            XCTAssertEqual(error, .disconnected)
        }

        XCTAssertEqual(await socket.sentCount(), 0)
        await socket.close()
    }

    func testStopAfterSendSurfacesUncertainDelivery() async throws {
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

        _ = try await socket.lastRequestID()
        await dispatcher.stop()

        do {
            _ = try await requestTask.value
            XCTFail("Expected uncertain delivery")
        } catch let error as AWLOpenClawError {
            XCTAssertEqual(error, .deliveryUncertain)
        }

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
}

private struct EmptyParams: Encodable, Sendable {}
