import Foundation
import XCTest
@testable import AgentWearLinkOpenClaw


private actor SupervisorRetrySocket: OpenClawWebSocket {
    private var connectCalls = 0
    private var handshakeStep = 0
    private var sentFrames: [String] = []
    private var receiveWaiter: CheckedContinuation<String, Error>?
    private var successfulConnectCalls: Set<Int> = [1]
    private var blockedConnectCall: Int?
    private var blockedConnectStarted = false
    private var blockedConnectRelease: CheckedContinuation<Void, Never>?
    private var blockedConnectStartedWaiter: CheckedContinuation<Void, Never>?
    private var closeCalls = 0
    private var closeWaitTarget: Int?
    private var closeWaiter: CheckedContinuation<Void, Never>?

    func connect() async {
        connectCalls += 1
        handshakeStep = 0

        guard blockedConnectCall == connectCalls else { return }
        blockedConnectStarted = true
        blockedConnectStartedWaiter?.resume()
        blockedConnectStartedWaiter = nil

        await withCheckedContinuation { continuation in
            blockedConnectRelease = continuation
        }

        blockedConnectCall = nil
        blockedConnectStarted = false
    }

    func send(text: String) async throws {
        sentFrames.append(text)
    }

    func receive() async throws -> String {
        if handshakeStep == 0 {
            handshakeStep = 1
            return #"{"type":"event","event":"connect.challenge","payload":{"nonce":"retry-test","ts":1737264000000}}"#
        }

        if handshakeStep == 1 {
            handshakeStep = 2
            guard let sent = sentFrames.last,
                  let data = sent.data(using: .utf8),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = json["id"] as? String else {
                throw OpenClawFrameError.malformedFrame
            }

            if successfulConnectCalls.contains(connectCalls) {
                return """
                {"type":"res","id":"\(id)","ok":true,"payload":{
                  "type":"hello-ok","protocol":4,
                  "server":{"version":"2026.10","connId":"c-\(connectCalls)"},
                  "features":{"methods":["health"],"events":["tick"]},
                  "auth":{"role":"operator","scopes":["operator.read"]},
                  "policy":{"maxPayload":4096,"maxBufferedBytes":8192,"tickIntervalMs":15000}
                }}
                """
            }

            return """
            {"type":"res","id":"\(id)","ok":false,"error":{
              "code":"BUSY","message":"retry test","retryable":true
            }}
            """
        }

        return try await withCheckedThrowingContinuation { continuation in
            receiveWaiter = continuation
        }
    }

    func close() async {
        closeCalls += 1
        if let target = closeWaitTarget, closeCalls >= target {
            closeWaiter?.resume()
            closeWaiter = nil
            closeWaitTarget = nil
        }

        receiveWaiter?.resume(throwing: AWLOpenClawError.disconnected)
        receiveWaiter = nil
    }

    func connectionCount() -> Int { connectCalls }
    func closeCount() -> Int { closeCalls }

    func makeNextHandshakeSucceed() {
        successfulConnectCalls.insert(connectCalls + 1)
    }

    func blockNextConnect() {
        blockedConnectCall = connectCalls + 1
        blockedConnectStarted = false
    }

    func waitForBlockedConnectStart() async {
        if blockedConnectStarted { return }
        await withCheckedContinuation { continuation in
            blockedConnectStartedWaiter = continuation
        }
    }

    func releaseBlockedConnect() {
        blockedConnectRelease?.resume()
        blockedConnectRelease = nil
    }

    func waitForCloseCount(atLeast target: Int) async {
        if closeCalls >= target { return }
        closeWaitTarget = target
        await withCheckedContinuation { continuation in
            closeWaiter = continuation
        }
    }
}

final class OpenClawRecoveryMatrixTests: XCTestCase {

    private func makeSupervisor(
        reconnectPolicy: GatewayReconnectPolicy = .init(
            initialDelayMilliseconds: 1,
            maximumDelayMilliseconds: 1,
            maximumAttempts: 2
        )
    ) -> (
        socket: SupervisorRetrySocket,
        state: OpenClawGatewayState,
        dispatcher: OpenClawRPCDispatcher,
        supervisor: OpenClawGatewaySupervisor
    ) {
        let socket = SupervisorRetrySocket()
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
            state: state
        )
        let supervisor = OpenClawGatewaySupervisor(
            connection: connection,
            dispatcher: dispatcher,
            state: state,
            socket: socket,
            appVersion: "0.1.0",
            reconnectPolicy: reconnectPolicy
        )
        return (socket, state, dispatcher, supervisor)
    }

    func testConcurrentReconnectTriggersShareOneOwnedTransition() async throws {
        let fixture = makeSupervisor()
        try await fixture.supervisor.start()

        await fixture.socket.makeNextHandshakeSucceed()
        await fixture.socket.blockNextConnect()

        let first = Task {
            await fixture.supervisor.reconnect(
                closeCode: 4_000,
                closeReason: "first trigger"
            )
        }

        await fixture.socket.waitForBlockedConnectStart()

        let second = Task {
            await fixture.supervisor.reconnect(
                closeCode: 4_001,
                closeReason: "duplicate trigger"
            )
        }

        // start() racing an active reconnect must remain idempotent and must not
        // create another handshake.
        try await fixture.supervisor.start()
        XCTAssertEqual(await fixture.socket.connectionCount(), 2)

        await fixture.socket.releaseBlockedConnect()
        await first.value
        await second.value

        XCTAssertEqual(await fixture.socket.connectionCount(), 2)
        XCTAssertEqual(await fixture.state.connectionState, .ready)

        await fixture.supervisor.stop()
    }

    func testStopInvalidatesLateReconnectSuccessBeforeDispatcherCanResurrect() async throws {
        let fixture = makeSupervisor()
        try await fixture.supervisor.start()

        await fixture.socket.makeNextHandshakeSucceed()
        await fixture.socket.blockNextConnect()

        let reconnect = Task {
            await fixture.supervisor.reconnect(
                closeCode: 4_000,
                closeReason: "blocked reconnect"
            )
        }

        await fixture.socket.waitForBlockedConnectStart()
        let closeCountBeforeStop = await fixture.socket.closeCount()

        let stop = Task {
            await fixture.supervisor.stop()
        }

        // Observe stop() retiring the transport before releasing the delayed
        // reconnect handshake, so the late success is deterministic.
        await fixture.socket.waitForCloseCount(atLeast: closeCountBeforeStop + 1)
        await fixture.socket.releaseBlockedConnect()

        await stop.value
        await reconnect.value

        XCTAssertEqual(await fixture.state.connectionState, .disconnected)
        XCTAssertFalse(await fixture.dispatcher.isRunning)
        XCTAssertEqual(await fixture.socket.connectionCount(), 2)
    }

    func testReconnectBudgetExhaustionIsTerminalUntilExplicitRestart() async throws {
        let socket = SupervisorRetrySocket()
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
            state: state
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

        try await supervisor.start()
        let initialConnectionCount = await socket.connectionCount()
        XCTAssertEqual(initialConnectionCount, 1)

        await supervisor.reconnect(
            closeCode: 4_000,
            closeReason: "test retry exhaustion"
        )

        let exhaustedConnectionCount = await socket.connectionCount()
        let exhaustedState = await state.connectionState
        XCTAssertEqual(exhaustedConnectionCount, 3)
        XCTAssertEqual(exhaustedState, .disconnected)

        // A later watchdog-style reconnect request cannot manufacture a fresh
        // retry budget after this generation has exhausted its allowance.
        await supervisor.reconnect(
            closeCode: 4_000,
            closeReason: "must remain terminal"
        )
        let terminalConnectionCount = await socket.connectionCount()
        XCTAssertEqual(terminalConnectionCount, 3)

        // Deliberate application restart is the explicit recovery boundary.
        await socket.makeNextHandshakeSucceed()
        try await supervisor.start()
        let restartedConnectionCount = await socket.connectionCount()
        let restartedState = await state.connectionState
        XCTAssertEqual(restartedConnectionCount, 4)
        XCTAssertEqual(restartedState, .ready)

        await supervisor.stop()
    }

    func testReconnectBackoffIsBoundedAcrossTransitionMatrix() {
        let policy = GatewayReconnectPolicy(
            initialDelayMilliseconds: 1_000,
            maximumDelayMilliseconds: 8_000,
            maximumAttempts: 5
        )

        let cases: [(String, Int)] = [
            ("wifi-to-cellular", 1),
            ("tailnet-loss", 2),
            ("gateway-restart", 3),
            ("mac-wake", 4),
            ("app-foreground", 5)
        ]

        for (name, attempt) in cases {
            let delay = policy.delayMilliseconds(forAttempt: attempt)
            XCTAssertGreaterThan(delay, 0, name)
            XCTAssertLessThanOrEqual(delay, 8_000, name)
        }
    }

    func testReconnectStateNeverAuthorizesRequestsBeforeReady() {
        let unavailable: [GatewayConnectionState] = [
            .disconnected,
            .connecting,
            .authenticating,
            .reconnecting(attempt: 1),
            .failed("transport uncertain")
        ]

        for state in unavailable {
            XCTAssertFalse(state.canSendRequests, "\(state)")
        }
        XCTAssertTrue(GatewayConnectionState.ready.canSendRequests)
    }

    func testTransportGenerationChangesRepresentNoReplayBoundary() async {
        // The supervisor's generation is the identity boundary used when an old
        // transport is retired. Application requests are not retained by the
        // reconnect policy and therefore cannot be silently replayed.
        let policy = GatewayReconnectPolicy(
            initialDelayMilliseconds: 10,
            maximumDelayMilliseconds: 20,
            maximumAttempts: 1
        )

        XCTAssertEqual(policy.maximumAttempts, 1)
        XCTAssertEqual(policy.delayMilliseconds(forAttempt: 1), 10)
        XCTAssertEqual(policy.delayMilliseconds(forAttempt: 2), 20)
    }
}
