import AgentWearLinkCore
import Foundation
import XCTest
@testable import AgentWearLinkOpenClaw

private actor ExistingSessionAdapterSocket: OpenClawWebSocket {
    enum TerminalMode: Sendable, Equatable {
        case success
        case failure
    }

    private let terminalMode: TerminalMode
    private var generation: UInt64 = 0
    private var connected = false
    private var inbound: [String] = []
    private var receiveWaiter: CheckedContinuation<String, Error>?

    private(set) var submittedSessionKeys: [String?] = []
    private(set) var waitedRunIDs: [String] = []
    private(set) var abortedRunIDs: [String] = []

    init(terminalMode: TerminalMode) {
        self.terminalMode = terminalMode
    }

    func connect() async {
        generation &+= 1
        connected = true
        enqueue(
            #"{"type":"event","event":"connect.challenge","payload":{"nonce":"existing-session","ts":1737264000000}}"#
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
        guard connected else {
            throw AWLOpenClawError.disconnected
        }

        return try await withCheckedThrowingContinuation { continuation in
            receiveWaiter = continuation
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

    func submittedSessionKeysSnapshot() -> [String?] {
        submittedSessionKeys
    }

    func waitedRunIDsSnapshot() -> [String] {
        waitedRunIDs
    }

    func abortedRunIDsSnapshot() -> [String] {
        abortedRunIDs
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
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? String,
              let method = object["method"] as? String else {
            throw OpenClawFrameError.malformedFrame
        }

        let params = object["params"] as? [String: Any] ?? [:]

        switch method {
        case "connect":
            enqueue(
                #"{"type":"res","id":"\#(id)","ok":true,"payload":{"type":"hello-ok","protocol":4,"server":{"version":"test","connId":"existing-session"},"features":{"methods":["agent","agent.wait","chat.abort"],"events":["agent"]},"auth":{"role":"operator","scopes":["operator.read","operator.write"]},"policy":{"maxPayload":26214400,"maxBufferedBytes":52428800,"tickIntervalMs":60000}}}"#
            )

        case "agent":
            submittedSessionKeys.append(params["sessionKey"] as? String)
            enqueue(
                #"{"type":"res","id":"\#(id)","ok":true,"payload":{"runId":"run-existing-session","acceptedAt":1737264000001,"status":"accepted","sessionKey":"agent:main:main","agentId":"main"}}"#
            )

            // This other-run event must never leak into the requested interaction.
            enqueue(
                #"{"type":"event","event":"agent","seq":1,"payload":{"runId":"run-other","stream":"assistant","seq":1,"data":{"delta":"ignore-me"}}}"#
            )


        case "agent.wait":
            let runID = params["runId"] as? String ?? ""
            waitedRunIDs.append(runID)

            // The production adapter installs the run-scoped update stream
            // before issuing agent.wait. Emit target-run updates at that
            // boundary so this fixture proves ordering without scheduler races.
            enqueue(
                #"{"type":"event","event":"agent","seq":2,"payload":{"runId":"run-existing-session","stream":"assistant","seq":1,"data":{"delta":"partial"}}}"#
            )
            if terminalMode == .success {
                enqueue(
                    #"{"type":"event","event":"agent","seq":3,"payload":{"runId":"run-existing-session","stream":"assistant","seq":2,"data":{"delta":" complete"}}}"#
                )
            }

            switch terminalMode {
            case .success:
                enqueue(
                    #"{"type":"res","id":"\#(id)","ok":true,"payload":{"status":"ok","startedAt":1737264000001,"endedAt":1737264000002,"stopReason":"end_turn","livenessState":"terminal","yielded":true,"providerStarted":true,"terminalReply":{"text":"partial complete"},"sourceReplyDelivered":true}}"#
                )
            case .failure:
                enqueue(
                    #"{"type":"res","id":"\#(id)","ok":true,"payload":{"status":"error","startedAt":1737264000001,"endedAt":1737264000002,"livenessState":"terminal","error":"synthetic terminal failure"}}"#
                )
            }

        case "chat.abort":
            let runID = params["runId"] as? String ?? ""
            abortedRunIDs.append(runID)
            enqueue(
                #"{"type":"res","id":"\#(id)","ok":true,"payload":{"aborted":true,"runIds":["\#(runID)"]}}"#
            )

        default:
            throw AWLOpenClawError.gateway(
                code: "UNEXPECTED_TEST_METHOD",
                retryable: false
            )
        }
    }
}

final class OpenClawExistingSessionAdapterTests: XCTestCase {
    func testExistingSessionRunsThroughProductionAdapterWithoutReplay() async throws {
        let id = InteractionID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000234")!
        )
        let socket = ExistingSessionAdapterSocket(terminalMode: .success)
        let adapter = makeAdapter(socket: socket)

        try await adapter.connect()
        do {
            let stream = await adapter.responses(
                for: AgentRequest(interactionID: id, text: "continue")
            )

            var responses: [AgentResponse] = []
            for try await response in stream {
                responses.append(response)
            }

            XCTAssertEqual(
                responses,
                [
                    .textDelta(id, "partial"),
                    .textDelta(id, " complete"),
                    .completed(id)
                ]
            )

            let submittedSessions = await socket.submittedSessionKeysSnapshot()
            let waitedRunIDs = await socket.waitedRunIDsSnapshot()
            XCTAssertEqual(submittedSessions, ["agent:main:main"])
            XCTAssertEqual(waitedRunIDs, ["run-existing-session"])

            try await waitUntilOpenClawTestCondition(
                "native adapter retired completed run"
            ) {
                await adapter.activeRunCountForTesting() == 0
            }

            // A completed run is no longer cancellable remotely. This also proves
            // the adapter registry did not retain the accepted run.
            let outcome = await adapter.cancellationOutcome(interactionID: id)
            XCTAssertEqual(outcome, .handled)
            let aborts = await socket.abortedRunIDsSnapshot()
            XCTAssertTrue(aborts.isEmpty)

            await adapter.disconnect()
        } catch {
            await adapter.disconnect()
            throw error
        }
    }

    func testExistingSessionTerminalFailureUsesAcceptedRunAndTerminates() async throws {
        let id = InteractionID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000235")!
        )
        let socket = ExistingSessionAdapterSocket(terminalMode: .failure)
        let adapter = makeAdapter(socket: socket)

        try await adapter.connect()
        do {
            let stream = await adapter.responses(
                for: AgentRequest(interactionID: id, text: "continue")
            )

            var responses: [AgentResponse] = []
            for try await response in stream {
                responses.append(response)
            }

            XCTAssertEqual(
                responses,
                [
                    .textDelta(id, "partial"),
                    .failed(id, .agent("synthetic terminal failure"))
                ]
            )
            let waitedRunIDs = await socket.waitedRunIDsSnapshot()
            XCTAssertEqual(waitedRunIDs, ["run-existing-session"])

            try await waitUntilOpenClawTestCondition(
                "native adapter retired failed run"
            ) {
                await adapter.activeRunCountForTesting() == 0
            }

            await adapter.disconnect()
        } catch {
            await adapter.disconnect()
            throw error
        }
    }

    private func makeAdapter(
        socket: ExistingSessionAdapterSocket
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
            reconnectPolicy: .init(maximumAttempts: 1)
        )
        let runClient = OpenClawAgentRunClient(dispatcher: dispatcher)

        return OpenClawNativeAgentAdapter(
            supervisor: supervisor,
            dispatcher: dispatcher,
            runClient: runClient,
            sessionKey: "agent:main:main",
            maximumTerminalWaitPolls: 2,
            terminalPollTimeoutMilliseconds: 1_000
        )
    }
}
