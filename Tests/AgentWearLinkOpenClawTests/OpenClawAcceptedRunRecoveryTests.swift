import AgentWearLinkCore
import Foundation
import XCTest
@testable import AgentWearLinkOpenClaw

private actor AcceptedRunRecoverySocket: OpenClawWebSocket {
    enum PostReconnectMode: Sendable, Equatable {
        case success
        case runLost
        case blockForCancellation
    }

    private let mode: PostReconnectMode
    private var generation: UInt64 = 0
    private var connected = false
    private var inbound: [String] = []
    private var receiveWaiter: CheckedContinuation<String, Error>?
    private var failNextReceive = false

    private var connections = 0
    private var submissions = 0
    private var waits = 0
    private var aborts = 0

    private var secondConnectStarted = false
    private var secondConnectReleased = false
    private var secondConnectStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var secondConnectReleaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(mode: PostReconnectMode) {
        self.mode = mode
    }

    func connect() async {
        connections += 1

        if connections == 2, mode == .blockForCancellation {
            secondConnectStarted = true
            let starts = secondConnectStartWaiters
            secondConnectStartWaiters.removeAll()
            for waiter in starts { waiter.resume() }

            if !secondConnectReleased {
                await withCheckedContinuation {
                    secondConnectReleaseWaiters.append($0)
                }
            }
        }

        generation &+= 1
        connected = true
        enqueue(
            #"{"type":"event","event":"connect.challenge","payload":{"nonce":"accepted-run-recovery","ts":1737264000000}}"#
        )
    }

    func transportGeneration() async -> UInt64? {
        connected ? generation : nil
    }

    func send(text: String) async throws {
        try handle(text)
    }

    func send(
        text: String,
        expectedGeneration: UInt64
    ) async throws {
        guard connected, generation == expectedGeneration else {
            throw OpenClawTransportSendError.staleGeneration
        }
        try Task.checkCancellation()
        try handle(text)
        guard connected, generation == expectedGeneration else {
            throw OpenClawTransportSendError.deliveryUncertain
        }
    }

    func receive() async throws -> String {
        if !inbound.isEmpty {
            return inbound.removeFirst()
        }
        if failNextReceive {
            failNextReceive = false
            throw AWLOpenClawError.disconnected
        }
        guard connected else {
            throw AWLOpenClawError.disconnected
        }

        return try await withCheckedThrowingContinuation {
            receiveWaiter = $0
        }
    }

    func close() async {
        connected = false
        generation &+= 1
        if let receiveWaiter {
            self.receiveWaiter = nil
            receiveWaiter.resume(throwing: AWLOpenClawError.disconnected)
        }
    }

    func close(code: Int, reason: String?) async {
        await close()
    }

    func waitUntilSecondConnectStarts() async {
        if secondConnectStarted { return }
        await withCheckedContinuation {
            secondConnectStartWaiters.append($0)
        }
    }

    func releaseSecondConnect() {
        secondConnectReleased = true
        let waiters = secondConnectReleaseWaiters
        secondConnectReleaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func counts() -> (
        connections: Int,
        submissions: Int,
        waits: Int,
        aborts: Int
    ) {
        (connections, submissions, waits, aborts)
    }

    private func enqueue(_ frame: String) {
        if let receiveWaiter {
            self.receiveWaiter = nil
            receiveWaiter.resume(returning: frame)
        } else {
            inbound.append(frame)
        }
    }

    private func handle(_ text: String) throws {
        guard let data = text.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let id = object["id"] as? String,
              let method = object["method"] as? String else {
            throw OpenClawFrameError.malformedFrame
        }

        switch method {
        case "connect":
            enqueue(
                #"{"type":"res","id":"\#(id)","ok":true,"payload":{"type":"hello-ok","protocol":4,"server":{"version":"test","connId":"accepted-recovery"},"features":{"methods":["agent","agent.wait","chat.abort"],"events":["agent"]},"auth":{"role":"operator","scopes":["operator.read","operator.write"]},"policy":{"maxPayload":26214400,"maxBufferedBytes":52428800,"tickIntervalMs":60000}}}"#
            )

        case "agent":
            submissions += 1
            enqueue(
                #"{"type":"res","id":"\#(id)","ok":true,"payload":{"runId":"run-recover","acceptedAt":1737264000001,"status":"accepted","sessionKey":"agent:main:main","agentId":"main"}}"#
            )

        case "agent.wait":
            waits += 1
            if waits == 1 {
                enqueue(
                    #"{"type":"event","event":"agent","seq":1,"payload":{"runId":"run-recover","stream":"assistant","seq":1,"data":{"delta":"before"}}}"#
                )
                // The dispatcher consumes the already-queued delta, then the
                // next receive fails and retires this transport generation.
                failNextReceive = true
                return
            }

            switch mode {
            case .success:
                // This post-reconnect live delta is intentionally suppressed by
                // the adapter; the terminal snapshot repairs the missing suffix.
                enqueue(
                    #"{"type":"event","event":"agent","seq":1,"payload":{"runId":"run-recover","stream":"assistant","seq":2,"data":{"delta":" should-not-double"}}}"#
                )
                enqueue(
                    #"{"type":"res","id":"\#(id)","ok":true,"payload":{"status":"ok","startedAt":1737264000001,"endedAt":1737264000002,"livenessState":"terminal","terminalReply":{"text":"before after"},"sourceReplyDelivered":true}}"#
                )

            case .runLost:
                enqueue(
                    #"{"type":"res","id":"\#(id)","ok":false,"error":{"code":"RUN_NOT_FOUND","message":"run was lost after gateway restart","retryable":false}}"#
                )

            case .blockForCancellation:
                throw AWLOpenClawError.gateway(
                    code: "UNEXPECTED_SECOND_WAIT",
                    retryable: false
                )
            }

        case "chat.abort":
            aborts += 1
            enqueue(
                #"{"type":"res","id":"\#(id)","ok":true,"payload":{"aborted":true,"runIds":["run-recover"]}}"#
            )

        default:
            throw AWLOpenClawError.gateway(
                code: "UNEXPECTED_TEST_METHOD",
                retryable: false
            )
        }
    }
}

final class OpenClawAcceptedRunRecoveryTests: XCTestCase {
    func testAcceptedRunReconnectsAndCompletesWithoutReplayingMutation() async throws {
        let socket = AcceptedRunRecoverySocket(mode: .success)
        let adapter = makeAdapter(socket: socket)
        let id = InteractionID()

        try await adapter.connect()
        let stream = await adapter.responses(
            for: AgentRequest(interactionID: id, text: "one mutation")
        )

        var responses: [AgentResponse] = []
        for try await response in stream {
            responses.append(response)
        }

        // The original transport can fail before its queued initial delta
        // reaches the consuming task. After recovery, the authoritative
        // terminal reply must still produce exactly one complete answer,
        // whether that arrives in one delta or as an appended suffix.
        let deltas = responses.compactMap { response -> String? in
            guard case let .textDelta(responseID, text) = response else {
                return nil
            }
            XCTAssertEqual(responseID, id)
            return text
        }
        XCTAssertEqual(deltas.joined(), "before after")
        XCTAssertEqual(responses.count, deltas.count + 1)
        XCTAssertEqual(responses.last, .completed(id))

        let counts = await socket.counts()
        XCTAssertEqual(counts.connections, 2)
        XCTAssertEqual(counts.submissions, 1)
        XCTAssertEqual(counts.waits, 2)

        await adapter.disconnect()
    }

    func testRunNotFoundAfterReconnectIsTerminalAndNeverReplaysMutation() async throws {
        let socket = AcceptedRunRecoverySocket(mode: .runLost)
        let adapter = makeAdapter(socket: socket)
        let id = InteractionID()

        try await adapter.connect()
        let stream = await adapter.responses(
            for: AgentRequest(interactionID: id, text: "one mutation")
        )

        var responses: [AgentResponse] = []
        do {
            for try await response in stream {
                responses.append(response)
            }
            XCTFail("Expected run-lost terminal error")
        } catch let error as AWLOpenClawError {
            XCTAssertEqual(
                error,
                .gateway(
                    code: "RUN_NOT_FOUND",
                    retryable: false,
                    retryAfterMilliseconds: nil
                )
            )
        }

        // A lost run may fail before an already-queued delta is consumed.
        // Either no partial text or one pre-disconnect delta is valid; neither
        // outcome may manufacture a replay or a false completion.
        XCTAssertTrue(
            responses.isEmpty || responses == [.textDelta(id, "before")],
            "Only the optional pre-disconnect partial delta may be emitted"
        )
        let counts = await socket.counts()
        XCTAssertEqual(counts.connections, 2)
        XCTAssertEqual(counts.submissions, 1)
        XCTAssertEqual(counts.waits, 2)

        await adapter.disconnect()
    }

    func testCancellationDuringReconnectAbortsAcceptedRunAfterRecovery() async throws {
        let socket = AcceptedRunRecoverySocket(mode: .blockForCancellation)
        let adapter = makeAdapter(socket: socket)
        let id = InteractionID()

        try await adapter.connect()
        let collector = Task { () -> [AgentResponse] in
            let stream = await adapter.responses(
                for: AgentRequest(interactionID: id, text: "cancel me")
            )
            var values: [AgentResponse] = []
            do {
                for try await response in stream {
                    values.append(response)
                }
            } catch {
                // Cancellation is the expected terminal path.
            }
            return values
        }

        await socket.waitUntilSecondConnectStarts()
        collector.cancel()
        await socket.releaseSecondConnect()
        _ = await collector.value

        try await waitUntilOpenClawTestCondition(
            "accepted run aborted after cancelled recovery"
        ) {
            let counts = await socket.counts()
            return counts.aborts == 1
        }

        let counts = await socket.counts()
        XCTAssertEqual(counts.connections, 2)
        XCTAssertEqual(counts.submissions, 1)
        XCTAssertEqual(counts.waits, 1)
        XCTAssertEqual(counts.aborts, 1)

        try await waitUntilOpenClawTestCondition(
            "cancelled accepted run retired"
        ) {
            await adapter.activeRunCountForTesting() == 0
        }

        await adapter.disconnect()
    }

    func testRunNotFoundIsNotClassifiedAsRecoverableTransportFailure() {
        let error = AWLOpenClawError.gateway(
            code: "RUN_NOT_FOUND",
            retryable: false
        )
        XCTAssertFalse(
            OpenClawNativeAgentAdapter
                .isRecoverableAcceptedRunTransportError(error)
        )
    }

    private func makeAdapter(
        socket: AcceptedRunRecoverySocket
    ) -> OpenClawNativeAgentAdapter {
        let state = OpenClawGatewayState()
        let assembler = OpenClawConnectAssembler(
            identityManager: .init(
                store: InMemoryOpenClawDeviceIdentityStore()
            ),
            credentialStore: InMemoryOpenClawDeviceCredentialStore()
        )
        let connection = OpenClawGatewayConnection(
            socket: socket,
            assembler: assembler,
            state: state
        )
        let dispatcher = OpenClawRPCDispatcher(
            socket: socket,
            state: state,
            requestTimeout: .seconds(2)
        )
        let supervisor = OpenClawGatewaySupervisor(
            connection: connection,
            dispatcher: dispatcher,
            state: state,
            socket: socket,
            appVersion: "0.1.0",
            reconnectPolicy: .init(
                initialDelayMilliseconds: 1,
                maximumDelayMilliseconds: 1,
                maximumAttempts: 2
            )
        )
        let runClient = OpenClawAgentRunClient(dispatcher: dispatcher)

        return OpenClawNativeAgentAdapter(
            supervisor: supervisor,
            dispatcher: dispatcher,
            runClient: runClient,
            sessionKey: "agent:main:main",
            maximumTerminalWaitPolls: 2,
            terminalPollTimeoutMilliseconds: 1_000,
            maximumAcceptedRunRecoveries: 1
        )
    }
}
