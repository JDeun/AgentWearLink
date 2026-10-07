private actor AgentEventSocket: OpenClawWebSocket {
    private var frames: [String]
    private let holdOpenAfterFrames: Bool

    init(frames: [String], holdOpenAfterFrames: Bool = false) {
        self.frames = frames
        self.holdOpenAfterFrames = holdOpenAfterFrames
    }

    func connect() async {}
    func send(text: String) async throws {}

    func receive() async throws -> String {
        if !frames.isEmpty {
            return frames.removeFirst()
        }
        if holdOpenAfterFrames {
            try await Task.sleep(for: .seconds(3_600))
        }
        throw AWLOpenClawError.disconnected
    }

    func close() async {}
}

import Foundation
import XCTest
@testable import AgentWearLinkOpenClaw

final class OpenClawAgentRunTests: XCTestCase {
    func testAgentEventDecodesAssistantStream() throws {
        let value: JSONValue = .object([
            "runId": .string("run-1"),
            "stream": .string("assistant"),
            "seq": .number(2),
            "data": .object(["delta": .string("안녕")])
        ])
        let data = try JSONEncoder().encode(value)
        let event = try JSONDecoder().decode(
            OpenClawAgentEvent.self,
            from: data
        )

        XCTAssertEqual(event.runId, "run-1")
        XCTAssertEqual(event.stream, "assistant")
        XCTAssertEqual(event.seq, 2)
        XCTAssertEqual(
            event.data,
            .object(["delta": .string("안녕")])
        )
    }

    func testWaitTimeoutRemainsNonTerminalRepresentation() throws {
        let data = Data(#"""
        {
          "status":"timeout",
          "timeoutPhase":"provider"
        }
        """#.utf8)

        let result = try JSONDecoder().decode(
            OpenClawAgentWaitResult.self,
            from: data
        )

        XCTAssertEqual(result.status, "timeout")
        XCTAssertNil(result.endedAt)
    }

    func testAcceptedRunKeepsResolvedSessionContext() throws {
        let data = Data(#"""
        {
          "runId":"run-1",
          "acceptedAt":123,
          "status":"accepted",
          "sessionKey":"agent:main:main",
          "agentId":"main"
        }
        """#.utf8)

        let accepted = try JSONDecoder().decode(
            OpenClawAgentAccepted.self,
            from: data
        )

        XCTAssertEqual(accepted.runId, "run-1")
        XCTAssertEqual(accepted.sessionKey, "agent:main:main")
        XCTAssertEqual(accepted.agentId, "main")
    }

    func testChatAbortTargetsExactRunAndSession() throws {
        let params = OpenClawChatAbortParams(
            sessionKey: "agent:main:main",
            runId: "run-1",
            agentId: "main"
        )
        let data = try JSONEncoder().encode(params)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(json?["runId"] as? String, "run-1")
        XCTAssertEqual(json?["sessionKey"] as? String, "agent:main:main")
        XCTAssertEqual(json?["agentId"] as? String, "main")
        XCTAssertNil(json?["clearQueued"])
    }

    func testAbortConfirmationMayOmitRunIds() throws {
        let data = Data(#"""
        {"aborted":true}
        """#.utf8)

        let result = try JSONDecoder().decode(
            OpenClawChatAbortResult.self,
            from: data
        )

        XCTAssertTrue(result.aborted)
        XCTAssertNil(result.runIds)
    }

    func testAgentUpdatesFilterOtherRunsAndPreserveIncrementalOrder() async throws {
        let state = OpenClawGatewayState()
        let socket = AgentEventSocket(frames: [
            #"{"type":"event","event":"agent","seq":1,"payload":{"runId":"other","stream":"assistant","seq":1,"data":{"delta":"ignore"}}}"#,
            #"{"type":"event","event":"agent","seq":2,"payload":{"runId":"run-1","stream":"assistant","seq":1,"data":{"delta":"hel"}}}"#,
            #"{"type":"event","event":"agent","seq":3,"payload":{"runId":"run-1","stream":"assistant","seq":2,"data":{"delta":"lo"}}}"#
        ])
        await state.beginConnect()
        try await state.acceptHello(
            OpenClawHelloOK(
                type: "hello-ok",
                protocolVersion: 4,
                server: .init(version: "test", connId: "c1"),
                features: .init(methods: [], events: ["agent"]),
                auth: .init(role: "operator", scopes: ["operator.read"], deviceToken: nil),
                policy: .init(maxPayload: 1024, maxBufferedBytes: 2048, tickIntervalMs: 15000, attachments: nil)
            )
        )
        let dispatcher = OpenClawRPCDispatcher(socket: socket, state: state)
        let client = OpenClawAgentRunClient(dispatcher: dispatcher)
        let updates = await client.updates(runID: "run-1")
        await dispatcher.start()

        var deltas: [String] = []
        do {
            for try await update in updates {
                if case let .assistant(_, .object(data)?) = update,
                   case let .string(delta)? = data["delta"] {
                    deltas.append(delta)
                }
            }
        } catch {
            // The finite mock retires the transport after delivering its frames.
        }

        XCTAssertEqual(deltas, ["hel", "lo"])
        await dispatcher.stop()
    }

    func testRunUpdatesFailFastWhenSlowConsumerOverflowsBoundedBuffer() async throws {
        let state = OpenClawGatewayState()
        let socket = AgentEventSocket(
            frames: [
                #"{"type":"event","event":"agent","seq":1,"payload":{"runId":"run-1","stream":"assistant","seq":1,"data":{"delta":"one"}}}"#,
                #"{"type":"event","event":"agent","seq":2,"payload":{"runId":"run-1","stream":"assistant","seq":2,"data":{"delta":"two"}}}"#,
                #"{"type":"event","event":"agent","seq":3,"payload":{"runId":"run-1","stream":"assistant","seq":3,"data":{"delta":"three"}}}"#
            ],
            holdOpenAfterFrames: true
        )
        await state.beginConnect()
        try await state.acceptHello(
            OpenClawHelloOK(
                type: "hello-ok",
                protocolVersion: 4,
                server: .init(version: "test", connId: "c1"),
                features: .init(methods: [], events: ["agent"]),
                auth: .init(
                    role: "operator",
                    scopes: ["operator.read"],
                    deviceToken: nil
                ),
                policy: .init(
                    maxPayload: 1024,
                    maxBufferedBytes: 2048,
                    tickIntervalMs: 15000,
                    attachments: nil
                )
            )
        )

        let dispatcher = OpenClawRPCDispatcher(socket: socket, state: state)
        let client = OpenClawAgentRunClient(
            dispatcher: dispatcher,
            updateBufferLimit: 2
        )
        let updates = await client.updates(runID: "run-1")
        await dispatcher.start()

        try await waitUntilOpenClawTestCondition(
            "run update buffer overflow"
        ) {
            await client.updateBufferOverflowCount == 1
        }

        var iterator = updates.makeAsyncIterator()
        let secondValue = try await iterator.next()
        let thirdValue = try await iterator.next()
        guard let second = secondValue, let third = thirdValue else {
            await dispatcher.stop()
            return XCTFail("Expected two buffered run updates before overflow")
        }

        if case let .assistant(_, .object(payload)?) = second,
           case let .string(delta)? = payload["delta"] {
            XCTAssertEqual(delta, "two")
        } else {
            XCTFail("Expected second assistant delta")
        }

        if case let .assistant(_, .object(payload)?) = third,
           case let .string(delta)? = payload["delta"] {
            XCTAssertEqual(delta, "three")
        } else {
            XCTFail("Expected third assistant delta")
        }

        do {
            _ = try await iterator.next()
            XCTFail("Expected bounded run-update overflow")
        } catch let error as OpenClawAgentRunError {
            XCTAssertEqual(error, .updateBufferOverflow("run-1"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let running = await dispatcher.isRunning
        XCTAssertTrue(running)
        await dispatcher.stop()
    }

    func testRunScopedRoutingDoesNotFanOutOtherRuns() async throws {
        var frames: [String] = []
        for index in 0..<50 {
            frames.append(
                #"{"type":"event","event":"agent","seq":\#(index * 2 + 1),"payload":{"runId":"run-a","stream":"assistant","seq":\#(index),"data":{"delta":"a\#(index)"}}}"#
            )
            frames.append(
                #"{"type":"event","event":"agent","seq":\#(index * 2 + 2),"payload":{"runId":"run-b","stream":"assistant","seq":\#(index),"data":{"delta":"b\#(index)"}}}"#
            )
        }
        frames.append(
            #"{"type":"event","event":"agent","seq":101,"payload":{"runId":"malformed"}}"#
        )

        let state = OpenClawGatewayState()
        let socket = AgentEventSocket(
            frames: frames,
            holdOpenAfterFrames: true
        )
        await state.beginConnect()
        try await state.acceptHello(
            OpenClawHelloOK(
                type: "hello-ok",
                protocolVersion: 4,
                server: .init(version: "test", connId: "c1"),
                features: .init(methods: [], events: ["agent"]),
                auth: .init(role: "operator", scopes: ["operator.read"], deviceToken: nil),
                policy: .init(
                    maxPayload: 1024,
                    maxBufferedBytes: 2048,
                    tickIntervalMs: 15000,
                    attachments: nil
                )
            )
        )

        let dispatcher = OpenClawRPCDispatcher(
            socket: socket,
            state: state,
            agentEventBufferLimit: 64,
            pendingAgentEventLimit: 128
        )
        let client = OpenClawAgentRunClient(dispatcher: dispatcher)
        let updatesA = await client.updates(runID: "run-a")
        let updatesB = await client.updates(runID: "run-b")

        let collectA = Task { () -> [String] in
            var values: [String] = []
            do {
                for try await update in updatesA {
                    if case let .assistant(_, .object(data)?) = update,
                       case let .string(delta)? = data["delta"] {
                        values.append(delta)
                        if values.count == 50 { return values }
                    }
                }
            } catch {
                // Finite socket completion ends the synthetic connection.
            }
            return values
        }
        let collectB = Task { () -> [String] in
            var values: [String] = []
            do {
                for try await update in updatesB {
                    if case let .assistant(_, .object(data)?) = update,
                       case let .string(delta)? = data["delta"] {
                        values.append(delta)
                        if values.count == 50 { return values }
                    }
                }
            } catch {
                // Test failure is asserted through the collected count below.
            }
            return values
        }

        await dispatcher.start()

        let a = await collectA.value
        let b = await collectB.value

        XCTAssertEqual(a.count, 50)
        XCTAssertEqual(b.count, 50)
        XCTAssertTrue(a.allSatisfy { $0.hasPrefix("a") })
        XCTAssertTrue(b.allSatisfy { $0.hasPrefix("b") })
        XCTAssertFalse(a.contains(where: { $0.hasPrefix("b") }))
        XCTAssertFalse(b.contains(where: { $0.hasPrefix("a") }))

        await dispatcher.stop()
    }

}
