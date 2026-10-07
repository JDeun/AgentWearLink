import Foundation
import XCTest
@testable import AgentWearLinkOpenClaw


private struct SupervisorPairingResponse: Sendable {
    let retryable: Bool
    let waitForResolution: Bool
    let pauseReconnect: Bool
    let recommendedNextStep: String
    let requestID: String
    let deviceID: String
    let retryAfterMilliseconds: Int?
}

private actor SupervisorRetrySocket: OpenClawWebSocket {
    private var connectCalls = 0
    private var transportGenerationValue: UInt64 = 0
    private var handshakeStep = 0
    private var sentFrames: [String] = []
    private var receiveWaiter: CheckedContinuation<String, Error>?
    private var failNextReceive = false
    private var successfulConnectCalls: Set<Int> = [1]
    private var pairingResponses: [Int: SupervisorPairingResponse] = [:]
    private var blockedConnectCall: Int?
    private var blockedConnectStarted = false
    private var blockedConnectRelease: CheckedContinuation<Void, Never>?
    private var blockedConnectStartedWaiter: CheckedContinuation<Void, Never>?
    private var closeCalls = 0
    private var closeWaitTarget: Int?
    private var closeWaiter: CheckedContinuation<Void, Never>?

    func connect() async {
        connectCalls += 1
        transportGenerationValue &+= 1
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

    func transportGeneration() async -> UInt64? {
        transportGenerationValue
    }

    func send(
        text: String,
        expectedGeneration: UInt64
    ) async throws {
        guard expectedGeneration == transportGenerationValue else {
            throw OpenClawTransportSendError.staleGeneration
        }
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
                  "auth":{"role":"operator","scopes":["operator.read","operator.write"]},
                  "policy":{"maxPayload":4096,"maxBufferedBytes":8192,"tickIntervalMs":15000}
                }}
                """
            }

            if let pairing = pairingResponses[connectCalls] {
                let retryAfter = pairing.retryAfterMilliseconds.map {
                    ",\"retryAfterMs\":\($0)"
                } ?? ""
                return """
                {"type":"res","id":"\(id)","ok":false,"error":{
                  "code":"NOT_PAIRED","message":"pairing required",
                  "retryable":\(pairing.retryable)\(retryAfter),
                  "details":{
                    "code":"PAIRING_REQUIRED",
                    "requestId":"\(pairing.requestID)",
                    "deviceId":"\(pairing.deviceID)",
                    "reason":"not-paired",
                    "recommendedNextStep":"\(pairing.recommendedNextStep)",
                    "waitForResolution":\(pairing.waitForResolution),
                    "pauseReconnect":\(pairing.pauseReconnect)
                  }
                }}
                """
            }

            return """
            {"type":"res","id":"\(id)","ok":false,"error":{
              "code":"BUSY","message":"retry test","retryable":true
            }}
            """
        }

        if failNextReceive {
            failNextReceive = false
            throw AWLOpenClawError.disconnected
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
    func sentCount() -> Int { sentFrames.count }

    func sentMethodCount(_ method: String) -> Int {
        sentFrames.reduce(into: 0) { count, frame in
            guard let data = frame.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any],
                  object["method"] as? String == method else {
                return
            }
            count += 1
        }
    }

    func failCurrentReceive() {
        if let receiveWaiter {
            self.receiveWaiter = nil
            receiveWaiter.resume(throwing: AWLOpenClawError.disconnected)
        } else {
            failNextReceive = true
        }
    }

    func makeNextHandshakeSucceed() {
        successfulConnectCalls.insert(connectCalls + 1)
    }

    func makeHandshakeSucceed(afterCurrentCount offset: Int) {
        precondition(offset > 0)
        successfulConnectCalls.insert(connectCalls + offset)
    }

    func makeNextHandshakeRequirePairing(
        retryable: Bool = true,
        waitForResolution: Bool = true,
        pauseReconnect: Bool = false,
        recommendedNextStep: String = "wait_then_retry",
        requestID: String = "pairing-request",
        deviceID: String = "pairing-device",
        retryAfterMilliseconds: Int? = nil
    ) {
        pairingResponses[connectCalls + 1] = SupervisorPairingResponse(
            retryable: retryable,
            waitForResolution: waitForResolution,
            pauseReconnect: pauseReconnect,
            recommendedNextStep: recommendedNextStep,
            requestID: requestID,
            deviceID: deviceID,
            retryAfterMilliseconds: retryAfterMilliseconds
        )
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

    func testReceiveFailureRevokesAdmissionAndTriggersPromptReconnect() async throws {
        let fixture = makeSupervisor()
        try await fixture.supervisor.start()

        await fixture.socket.makeNextHandshakeSucceed()
        await fixture.socket.blockNextConnect()

        let sentBeforeFailure = await fixture.socket.sentCount()
        await fixture.socket.failCurrentReceive()

        // The configured gateway tick interval is 15 seconds. Reaching the
        // second connect inside the bounded test deadline proves recovery came
        // from the dispatcher failure signal, not the periodic watchdog.
        try await waitUntilOpenClawTestCondition(
            "receive failure triggered reconnect immediately"
        ) {
            await fixture.socket.connectionCount() >= 2
        }

        let reconnectingState = await fixture.state.connectionState
        XCTAssertNotEqual(reconnectingState, .ready)

        do {
            _ = try await fixture.dispatcher.request(
                method: "agent",
                params: ["probe": "rejected"]
            )
            XCTFail("Expected receive failure to revoke request admission")
        } catch let error as AWLOpenClawError {
            XCTAssertEqual(error, .notReady)
        } catch {
            XCTFail("Unexpected request rejection: \(error)")
        }

        let sentWhileReconnectBlocked = await fixture.socket.sentCount()
        XCTAssertEqual(sentWhileReconnectBlocked, sentBeforeFailure)

        await fixture.socket.releaseBlockedConnect()

        try await waitUntilOpenClawTestCondition(
            "prompt reconnect restored ready dispatcher"
        ) {
            let ready = await fixture.state.connectionState == .ready
            let running = await fixture.dispatcher.isRunning
            return ready && running
        }

        await fixture.supervisor.stop()
    }

    func testStaleDispatcherWatchdogCheckReconnectsDeterministically() async throws {
        let fixture = makeSupervisor()
        try await fixture.supervisor.start()

        let initialGeneration = await fixture.supervisor.transportGeneration
        await fixture.socket.makeNextHandshakeSucceed()

        // Advance the watchdog's observation point without waiting for the
        // negotiated real-time tick interval. This drives the same production
        // stale-dispatcher branch used by watchdogLoop().
        await fixture.supervisor.runWatchdogCheck(nowMilliseconds: Int64.max)

        let finalGeneration = await fixture.supervisor.transportGeneration
        let finalConnectionCount = await fixture.socket.connectionCount()
        let finalState = await fixture.state.connectionState
        let dispatcherRunning = await fixture.dispatcher.isRunning

        XCTAssertEqual(finalConnectionCount, 2)
        XCTAssertGreaterThan(finalGeneration, initialGeneration)
        XCTAssertEqual(finalState, .ready)
        XCTAssertTrue(dispatcherRunning)

        await fixture.supervisor.stop()
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
        let connectionCountDuringReconnect = await fixture.socket.connectionCount()
        XCTAssertEqual(connectionCountDuringReconnect, 2)

        await fixture.socket.releaseBlockedConnect()
        await first.value
        await second.value

        let finalConnectionCount = await fixture.socket.connectionCount()
        let finalState = await fixture.state.connectionState
        XCTAssertEqual(finalConnectionCount, 2)
        XCTAssertEqual(finalState, .ready)

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

        let finalState = await fixture.state.connectionState
        let dispatcherRunning = await fixture.dispatcher.isRunning
        let finalConnectionCount = await fixture.socket.connectionCount()
        XCTAssertEqual(finalState, .disconnected)
        XCTAssertFalse(dispatcherRunning)
        XCTAssertEqual(finalConnectionCount, 2)
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

    func testRetryablePairingWaitReconnectsUntilApproved() async throws {
        let fixture = makeSupervisor(
            reconnectPolicy: .init(
                initialDelayMilliseconds: 1,
                maximumDelayMilliseconds: 1,
                maximumAttempts: 3
            )
        )
        try await fixture.supervisor.start()

        await fixture.socket.makeNextHandshakeRequirePairing(
            retryable: true,
            waitForResolution: true,
            pauseReconnect: false,
            recommendedNextStep: "wait_then_retry",
            retryAfterMilliseconds: 1
        )
        await fixture.socket.makeHandshakeSucceed(afterCurrentCount: 2)

        // After the pairing-required handshake, the same bounded reconnect
        // transition should retry rather than stopping.
        let reconnect = Task {
            await fixture.supervisor.reconnect(
                closeCode: 4_000,
                closeReason: "pairing wait"
            )
        }

        try await waitUntilOpenClawTestCondition(
            "pairing-required reconnect observed"
        ) {
            await fixture.socket.connectionCount() >= 2
        }
        await reconnect.value

        let connectionCount = await fixture.socket.connectionCount()
        let finalState = await fixture.state.connectionState
        XCTAssertEqual(connectionCount, 3)
        XCTAssertEqual(finalState, .ready)

        await fixture.supervisor.stop()
    }

    func testPauseReconnectPairingRequiresExplicitRestart() async throws {
        let fixture = makeSupervisor()
        try await fixture.supervisor.start()

        await fixture.socket.makeNextHandshakeRequirePairing(
            retryable: true,
            waitForResolution: true,
            pauseReconnect: true,
            recommendedNextStep: "wait_then_retry"
        )

        await fixture.supervisor.reconnect(
            closeCode: 4_000,
            closeReason: "pairing paused"
        )

        let pausedCount = await fixture.socket.connectionCount()
        let pausedState = await fixture.state.connectionState
        XCTAssertEqual(pausedCount, 2)
        XCTAssertEqual(pausedState, .disconnected)

        await fixture.socket.makeNextHandshakeSucceed()
        try await fixture.supervisor.start()

        let restartedCount = await fixture.socket.connectionCount()
        let restartedState = await fixture.state.connectionState
        XCTAssertEqual(restartedCount, 3)
        XCTAssertEqual(restartedState, .ready)

        await fixture.supervisor.stop()
    }

    func testNonRetryablePairingStopsReconnect() async throws {
        let fixture = makeSupervisor()
        try await fixture.supervisor.start()

        await fixture.socket.makeNextHandshakeRequirePairing(
            retryable: false,
            waitForResolution: true,
            pauseReconnect: false,
            recommendedNextStep: "wait_then_retry"
        )

        await fixture.supervisor.reconnect(
            closeCode: 4_000,
            closeReason: "pairing rejected"
        )

        let connectionCount = await fixture.socket.connectionCount()
        let finalState = await fixture.state.connectionState
        XCTAssertEqual(connectionCount, 2)
        XCTAssertEqual(finalState, .disconnected)

        await fixture.supervisor.stop()
    }

    func testStopInvalidatesPairingWaitBeforeNextRetry() async throws {
        let fixture = makeSupervisor(
            reconnectPolicy: .init(
                initialDelayMilliseconds: 100,
                maximumDelayMilliseconds: 100,
                maximumAttempts: 3
            )
        )
        try await fixture.supervisor.start()

        await fixture.socket.makeNextHandshakeRequirePairing(
            retryable: true,
            waitForResolution: true,
            pauseReconnect: false,
            recommendedNextStep: "wait_then_retry"
        )

        let reconnect = Task {
            await fixture.supervisor.reconnect(
                closeCode: 4_000,
                closeReason: "pairing wait cancellation"
            )
        }

        try await waitUntilOpenClawTestCondition(
            "pairing wait entered"
        ) {
            await fixture.socket.connectionCount() >= 2
        }

        await fixture.supervisor.stop()
        await reconnect.value

        let finalCount = await fixture.socket.connectionCount()
        let finalState = await fixture.state.connectionState
        XCTAssertEqual(finalCount, 2)
        XCTAssertEqual(finalState, .disconnected)
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

    func testUncertainMutatingRequestIsNeverReplayedAcrossReconnect() async throws {
        let fixture = makeSupervisor()
        try await fixture.supervisor.start()

        let initialTransportGeneration = await fixture.supervisor.transportGeneration
        let request = Task {
            try await fixture.dispatcher.request(
                method: "agent",
                params: SupervisorMutatingParams(message: "execute-once")
            )
        }

        try await waitUntilOpenClawTestCondition(
            "mutating request reached the first transport"
        ) {
            await fixture.socket.sentMethodCount("agent") == 1
        }

        // Retire the transport while the mutating request has no authoritative
        // response. The supervisor may restore transport, but it must never
        // retain or resubmit the application request.
        await fixture.socket.makeNextHandshakeSucceed()
        await fixture.socket.failCurrentReceive()

        do {
            _ = try await request.value
            XCTFail("Expected the in-flight request outcome to become uncertain")
        } catch {
            // The exact transport-facing error is intentionally not treated as
            // permission to replay. The invariant below is the contract.
        }

        try await waitUntilOpenClawTestCondition(
            "supervisor restored a fresh transport"
        ) {
            let ready = await fixture.state.connectionState == .ready
            let running = await fixture.dispatcher.isRunning
            return ready && running
        }

        let finalTransportGeneration = await fixture.supervisor.transportGeneration
        let mutatingSendCount = await fixture.socket.sentMethodCount("agent")
        XCTAssertGreaterThan(finalTransportGeneration, initialTransportGeneration)
        XCTAssertEqual(mutatingSendCount, 1)

        await fixture.supervisor.stop()
    }
}

private struct SupervisorMutatingParams: Encodable, Sendable {
    let message: String
}
