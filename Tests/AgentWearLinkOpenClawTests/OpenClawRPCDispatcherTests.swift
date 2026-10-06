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

    func lastRequestID() throws -> String {
        guard let text = sentFrames.last,
              let data = text.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String else {
            throw OpenClawFrameError.malformedFrame
        }
        return id
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

        await Task.yield()
        let id = try await socket.lastRequestID()
        await socket.push(
            #"{"type":"res","id":"#(id)","ok":true,"payload":{"status":"ok"}}"#
        )

        let response = try await requestTask.value
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.id, id)
        await dispatcher.stop()
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
