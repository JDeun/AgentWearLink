import Foundation
import XCTest
@testable import AgentWearLinkOpenClaw

private actor DispatcherSocket: OpenClawWebSocket {
    private var inbound: [String] = []
    private var waiter: CheckedContinuation<String, Error>?
    private var sentFrames: [String] = []
    private var generation: UInt64 = 1

    func connect() async {}

    func send(text: String) async throws {
        sentFrames.append(text)
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


private actor GenerationGateSocket: OpenClawWebSocket {
    private var generation: UInt64 = 1
    private var sendEntered = false
    private var sendReleased = false
    private var releaseWaiter: CheckedContinuation<Void, Never>?
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
        try await Task.sleep(for: .seconds(3_600))
        throw AWLOpenClawError.disconnected
    }

    func close() async {}

    func waitUntilSendEntered() async {
        while !sendEntered {
            await Task.yield()
        }
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

        await socket.waitUntilSendEntered()

        let stopTask = Task {
            await dispatcher.stop()
        }
        await Task.yield()

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

        XCTAssertEqual(await socket.sentCount(), 0)
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

        await socket.waitUntilSendEntered()

        let stopTask = Task {
            await dispatcher.stop()
        }
        await Task.yield()

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

        XCTAssertEqual(await socket.sentCount(), 1)
    }


}

private struct EmptyParams: Encodable, Sendable {}
