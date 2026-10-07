import Foundation
import XCTest
@testable import AgentWearLinkOpenClaw

final class OpenClawGatewayConnectionConcurrencyTests: XCTestCase {
    private func makeAssembler(
        identity: OpenClawDeviceIdentity = .generate(),
        credentialStore: InMemoryOpenClawDeviceCredentialStore = .init()
    ) -> (OpenClawConnectAssembler, OpenClawDeviceIdentity, InMemoryOpenClawDeviceCredentialStore) {
        let assembler = OpenClawConnectAssembler(
            identityManager: .init(
                store: InMemoryOpenClawDeviceIdentityStore(identity: identity)
            ),
            credentialStore: credentialStore
        )
        return (assembler, identity, credentialStore)
    }

    func testRejectsSecondConnectWhileHandshakeIsInFlight() async throws {
        let socket = ControlledHandshakeSocket()
        let (assembler, _, _) = makeAssembler()
        let connection = OpenClawGatewayConnection(
            socket: socket,
            assembler: assembler,
            handshakeTimeout: .seconds(30)
        )

        let first = Task {
            try await connection.connect(appVersion: "0.1.0")
        }
        await socket.waitUntilReceiveCount(1)

        do {
            _ = try await connection.connect(appVersion: "0.1.0")
            XCTFail("Expected concurrent connect rejection")
        } catch let error as OpenClawHandshakeError {
            XCTAssertEqual(error, .connectInProgress)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        await connection.disconnect()
        await socket.failReceiveDisconnected(id: 0)
        _ = try? await first.value

        let sentCount = await socket.sentCount()
        XCTAssertEqual(sentCount, 0)
    }

    func testDisconnectDuringChallengeInvalidatesLateChallengeBeforeSend() async throws {
        let socket = ControlledHandshakeSocket()
        let state = OpenClawGatewayState()
        let (assembler, _, _) = makeAssembler()
        let connection = OpenClawGatewayConnection(
            socket: socket,
            assembler: assembler,
            state: state,
            handshakeTimeout: .seconds(30)
        )

        let connect = Task {
            try await connection.connect(appVersion: "0.1.0")
        }
        await socket.waitUntilReceiveCount(1)

        await connection.disconnect()
        await socket.resumeReceive(
            id: 0,
            text: ControlledHandshakeSocket.challenge(nonce: "late-challenge")
        )

        do {
            _ = try await connect.value
            XCTFail("Expected invalidated handshake")
        } catch let error as OpenClawHandshakeError {
            XCTAssertEqual(error, .connectInvalidated)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let sentCount = await socket.sentCount()
        let connectionState = await state.connectionState
        let closeCount = await socket.closeCount()
        XCTAssertEqual(sentCount, 0)
        XCTAssertEqual(connectionState, .disconnected)
        XCTAssertEqual(closeCount, 1)
    }

    func testDisconnectDuringHelloPreventsLateCredentialPersistenceAndReady() async throws {
        let socket = ControlledHandshakeSocket()
        let state = OpenClawGatewayState()
        let identity = OpenClawDeviceIdentity.generate()
        let credentialStore = InMemoryOpenClawDeviceCredentialStore()
        let (assembler, _, _) = makeAssembler(
            identity: identity,
            credentialStore: credentialStore
        )
        let connection = OpenClawGatewayConnection(
            socket: socket,
            assembler: assembler,
            state: state,
            handshakeTimeout: .seconds(30)
        )

        let connect = Task {
            try await connection.connect(
                appVersion: "0.1.0",
                scopes: ["operator.read"]
            )
        }

        await socket.waitUntilReceiveCount(1)
        await socket.resumeReceive(
            id: 0,
            text: ControlledHandshakeSocket.challenge(nonce: "hello-race")
        )
        await socket.waitUntilSentCount(1)
        await socket.waitUntilReceiveCount(2)

        await connection.disconnect()
        await socket.resumeHello(id: 1, deviceToken: "late-device-token")

        do {
            _ = try await connect.value
            XCTFail("Expected invalidated handshake")
        } catch let error as OpenClawHandshakeError {
            XCTAssertEqual(error, .connectInvalidated)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let persisted = try await credentialStore.load(
            deviceID: try identity.deviceID,
            role: "operator"
        )
        XCTAssertNil(persisted)
        let connectionState = await state.connectionState
        let hello = await state.hello
        XCTAssertEqual(connectionState, .disconnected)
        XCTAssertNil(hello)
    }

    func testStaleFailureCannotCloseReplacementConnection() async throws {
        let socket = ControlledHandshakeSocket()
        let state = OpenClawGatewayState()
        let (assembler, _, _) = makeAssembler()
        let connection = OpenClawGatewayConnection(
            socket: socket,
            assembler: assembler,
            state: state,
            handshakeTimeout: .seconds(30)
        )

        let stale = Task {
            try await connection.connect(appVersion: "0.1.0")
        }
        await socket.waitUntilReceiveCount(1)

        await connection.disconnect()
        let closeCountAfterDisconnect = await socket.closeCount()
        XCTAssertEqual(closeCountAfterDisconnect, 1)

        let replacement = Task {
            try await connection.connect(appVersion: "0.1.0")
        }
        await socket.waitUntilReceiveCount(2)

        await socket.failReceiveDisconnected(id: 0)
        _ = try? await stale.value

        // The stale connect no longer owns the socket and must not close the
        // replacement transport during its catch cleanup.
        let closeCountAfterStaleFailure = await socket.closeCount()
        XCTAssertEqual(closeCountAfterStaleFailure, 1)

        await socket.resumeReceive(
            id: 1,
            text: ControlledHandshakeSocket.challenge(nonce: "replacement")
        )
        await socket.waitUntilSentCount(1)
        await socket.waitUntilReceiveCount(3)
        await socket.resumeHello(id: 2)

        let hello = try await replacement.value
        XCTAssertEqual(hello.server.connId, "replacement-conn")
        let readyState = await state.connectionState
        let closeCountBeforeFinalDisconnect = await socket.closeCount()
        XCTAssertEqual(readyState, .ready)
        XCTAssertEqual(closeCountBeforeFinalDisconnect, 1)

        await connection.disconnect()
    }

    func testCallerCancellationFencesLateChallengeBeforeSend() async throws {
        let socket = ControlledHandshakeSocket()
        let (assembler, _, _) = makeAssembler()
        let connection = OpenClawGatewayConnection(
            socket: socket,
            assembler: assembler,
            handshakeTimeout: .seconds(30)
        )

        let connect = Task {
            try await connection.connect(appVersion: "0.1.0")
        }
        await socket.waitUntilReceiveCount(1)

        connect.cancel()
        await socket.resumeReceive(
            id: 0,
            text: ControlledHandshakeSocket.challenge(nonce: "cancelled")
        )

        do {
            _ = try await connect.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let sentCount = await socket.sentCount()
        XCTAssertEqual(sentCount, 0)
    }
}

private actor ControlledHandshakeSocket: OpenClawWebSocket {
    private var receiveSequence = 0
    private var receives: [Int: CheckedContinuation<String, Error>] = [:]
    private var sentFrames: [String] = []
    private var receiveWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var sendWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var closes = 0

    func connect() async {}

    func send(text: String) async throws {
        sentFrames.append(text)
        resolveSendWaiters()
    }

    func receive() async throws -> String {
        let id = receiveSequence
        receiveSequence += 1
        resolveReceiveWaiters()

        return try await withCheckedThrowingContinuation { continuation in
            receives[id] = continuation
        }
    }

    // Deliberately does not resume blocked receives. These tests model an
    // underlying transport that is slow to observe close/cancellation so the
    // connection actor's own generation fence is what guarantees safety.
    func close() async {
        closes += 1
    }

    func waitUntilReceiveCount(_ target: Int) async {
        if receiveSequence >= target { return }
        await withCheckedContinuation { continuation in
            receiveWaiters.append((target, continuation))
        }
    }

    func waitUntilSentCount(_ target: Int) async {
        if sentFrames.count >= target { return }
        await withCheckedContinuation { continuation in
            sendWaiters.append((target, continuation))
        }
    }

    func resumeReceive(id: Int, text: String) {
        guard let continuation = receives.removeValue(forKey: id) else {
            return
        }
        continuation.resume(returning: text)
    }

    func failReceiveDisconnected(id: Int) {
        guard let continuation = receives.removeValue(forKey: id) else {
            return
        }
        continuation.resume(throwing: AWLOpenClawError.disconnected)
    }

    func resumeHello(id: Int, deviceToken: String? = nil) {
        guard let continuation = receives.removeValue(forKey: id) else {
            return
        }

        guard let sent = sentFrames.last,
              let data = sent.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let requestID = json["id"] as? String else {
            continuation.resume(throwing: OpenClawFrameError.malformedFrame)
            return
        }

        let auth: String
        if let deviceToken {
            auth = "\\\"auth\\\":{\\\"role\\\":\\\"operator\\\",\\\"scopes\\\":[\\\"operator.read\\\"],\\\"deviceToken\\\":\\\"\(deviceToken)\\\"}"
        } else {
            auth = "\\\"auth\\\":{\\\"role\\\":\\\"operator\\\",\\\"scopes\\\":[\\\"operator.read\\\"]}"
        }

        continuation.resume(returning: """
        {"type":"res","id":"\(requestID)","ok":true,"payload":{
          "type":"hello-ok","protocol":4,
          "server":{"version":"2026.10","connId":"replacement-conn"},
          "features":{"methods":["health"],"events":["agent"]},
          \(auth),
          "policy":{"maxPayload":26214400,"maxBufferedBytes":52428800,"tickIntervalMs":15000}
        }}
        """)
    }

    func sentCount() -> Int { sentFrames.count }
    func closeCount() -> Int { closes }

    static nonisolated func challenge(nonce: String) -> String {
        """
        {"type":"event","event":"connect.challenge","payload":{"nonce":"\(nonce)","ts":1737264000000}}
        """
    }

    private func resolveReceiveWaiters() {
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for (target, waiter) in receiveWaiters {
            if receiveSequence >= target {
                waiter.resume()
            } else {
                remaining.append((target, waiter))
            }
        }
        receiveWaiters = remaining
    }

    private func resolveSendWaiters() {
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for (target, waiter) in sendWaiters {
            if sentFrames.count >= target {
                waiter.resume()
            } else {
                remaining.append((target, waiter))
            }
        }
        sendWaiters = remaining
    }
}
