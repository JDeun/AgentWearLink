private actor AgentEventSocket: OpenClawWebSocket {
    private var frames: [String]
    init(frames: [String]) { self.frames = frames }
    func connect() async {}
    func send(text: String) async throws {}
    func receive() async throws -> String {
        guard !frames.isEmpty else { throw AWLOpenClawError.disconnected }
        return frames.removeFirst()
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
          "runId":"run-1",
          "status":"timeout"
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
        await state.markReady(
            OpenClawHelloOK(
                protocol: 4,
                server: .init(version: "test", connId: "c1"),
                features: .init(methods: [], events: ["agent"]),
                auth: .init(role: "operator", scopes: ["operator.read"], deviceToken: nil),
                policy: .init(maxPayload: 1024, maxBufferedBytes: 2048, tickIntervalMs: 15000)
            )
        )
        let dispatcher = OpenClawRPCDispatcher(socket: socket, state: state)
        let client = OpenClawAgentRunClient(dispatcher: dispatcher)
        let events = await dispatcher.events()
        let updates = await client.updates(from: events, runID: "run-1")
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

}
