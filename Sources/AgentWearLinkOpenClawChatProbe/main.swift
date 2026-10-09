import AgentWearLinkCore
import AgentWearLinkOpenClaw
import Foundation
import Darwin

@main
struct AgentWearLinkOpenClawChatProbe {
    static func main() async {
        let env = ProcessInfo.processInfo.environment
        let profile = OpenClawValidationProfile.mutating
        guard env["AWL_ALLOW_MUTATING_PROBE"] == "1" else {
            fail("Refusing to submit an agent run. Set AWL_ALLOW_MUTATING_PROBE=1 explicitly.", code: 2)
        }
        let endpoint = configuredEndpoint(environment: env)
        guard let message = nonEmpty(env["AWL_OPENCLAW_CHAT_MESSAGE"]) else {
            fail("AWL_OPENCLAW_CHAT_MESSAGE is required.", code: 2)
        }

        // Validate the isolated abort profile before constructing a socket or
        // initiating ANY Gateway connection. A direct CLI invocation must not
        // reach a personal Tailnet or carry a bootstrap token by accident.
        let isolatedAbortSession: String?
        if env["AWL_DEV_GATEWAY_ABORT_ASSERT"] == "1" {
            guard env["AWL_DEV_GATEWAY_ASSERT"] == "1",
                  env["AWL_ALLOW_DEV_GATEWAY_TEST"] == "1",
                  endpoint.exposure == .loopback,
                  env["AWL_OPENCLAW_BOOTSTRAP_TOKEN"] == nil,
                  message == "AWL isolated integration check: reply with one short sentence.",
                  let session = nonEmpty(env["AWL_OPENCLAW_SESSION_KEY"]),
                  session.range(
                      of: #"^agent:[A-Za-z0-9_-]+:awl-dev-[A-Za-z0-9_-]+$"#,
                      options: .regularExpression
                  ) != nil else {
                fail("Isolated loopback development Gateway and session are required for abort proof.", code: 2)
            }
            isolatedAbortSession = session
        } else {
            isolatedAbortSession = nil
        }

        let keychainService: String
        do {
            keychainService = try OpenClawDevelopmentKeychainIsolation.service(
                for: profile,
                environment: env,
                isLoopback: endpoint.exposure == .loopback
            )
        } catch {
            fail("Isolated development Keychain configuration is invalid.", code: 2)
        }

        let socket: URLSessionOpenClawWebSocket
        do {
            socket = try URLSessionOpenClawWebSocket(endpoint: endpoint)
        } catch {
            fail("Invalid OpenClaw WebSocket endpoint: \(String(describing: error))", code: 2)
        }

        let syntheticAgentStream = env["AWL_DEV_GATEWAY_EXPECT_AGENT_STREAM"] == "1"
        let syntheticAgentAbort = env["AWL_DEV_GATEWAY_EXPECT_AGENT_ABORT"] == "1"
        let syntheticAgentSession = env["AWL_DEV_GATEWAY_EXPECT_AGENT_SESSION"] == "1"
        if syntheticAgentSession {
            guard OpenClawDevelopmentAgentSessionPolicy.permits(
                environment: env,
                isLoopback: endpoint.exposure == .loopback,
                profile: profile
            ) else {
                fail("Synthetic session test requires isolated two-turn profile.", code: 2)
            }
        }
        if syntheticAgentAbort {
            guard OpenClawDevelopmentAgentAbortPolicy.permits(
                environment: env, isLoopback: endpoint.exposure == .loopback,
                profile: profile
            ) else {
                fail("Synthetic abort requires isolated held-model profile.", code: 2)
            }
        }
        if syntheticAgentStream {
            guard OpenClawDevelopmentAgentStreamPolicy.permits(
                environment: env,
                isLoopback: endpoint.exposure == .loopback,
                profile: profile
            ) else {
                fail("Synthetic agent stream requires isolated local mutating profile.", code: 2)
            }
        }
        let syntheticContract =
            syntheticAgentStream || syntheticAgentAbort || syntheticAgentSession
        let identityStore: any OpenClawDeviceIdentityStore =
            syntheticContract ? InMemoryOpenClawDeviceIdentityStore()
                : KeychainOpenClawDeviceIdentityStore(service: keychainService)
        let credentialStore: any OpenClawDeviceCredentialStore =
            syntheticContract ? InMemoryOpenClawDeviceCredentialStore()
                : KeychainOpenClawDeviceCredentialStore(service: keychainService)
        let state = OpenClawGatewayState()
        let assembler = OpenClawConnectAssembler(
            identityManager: .init(store: identityStore),
            credentialStore: credentialStore,
            gatewayNamespace: endpoint.credentialNamespace,
            bootstrapHandoffPersistenceAllowed:
                endpoint.allowsBootstrapHandoffPersistence
        )
        let connection = OpenClawGatewayConnection(
            socket: socket, assembler: assembler, state: state,
            progress: { phase in
                recordStreamPhase(phase.rawValue, environment: env)
            }
        )
        let dispatcher = OpenClawRPCDispatcher(socket: socket, state: state)
        let supervisor = OpenClawGatewaySupervisor(
            connection: connection,
            dispatcher: dispatcher,
            state: state,
            socket: socket,
            appVersion: "0.1.0-chat-probe",
            scopes: profile.scopes,
            credentials: .init(
                token: nonEmpty(env["AWL_OPENCLAW_TOKEN"]),
                bootstrapToken: nonEmpty(env["AWL_OPENCLAW_BOOTSTRAP_TOKEN"])
            ),
            clientIdentity: profile.clientIdentity
        )
        let client = OpenClawAgentRunClient(dispatcher: dispatcher)
        let adapter = OpenClawNativeAgentAdapter(
            supervisor: supervisor,
            dispatcher: dispatcher,
            runClient: client,
            sessionKey: nonEmpty(env["AWL_OPENCLAW_SESSION_KEY"])
        )
        let requireDevelopmentEvidence = env["AWL_DEV_GATEWAY_ASSERT"] == "1"

        do {
            recordStreamPhase("chat-started", environment: env)
            try await adapter.connect()
            recordStreamPhase("chat-authenticated", environment: env)

            // Extra opt-in proof against an isolated local REAL Gateway only.
            // This runs after the regular text/terminal smoke test in the
            // dedicated development harness; never against private Tailnet.
            if let isolatedSession = isolatedAbortSession {
                // A deliberately slow, harmless model is required. A run
                // already completed before chat.abort cannot demonstrate
                // confirmed remote cancellation and must fail this proof.
                let accepted = try await client.submit(
                    message: message,
                    sessionKey: isolatedSession,
                    idempotencyKey: UUID().uuidString
                )
                guard accepted.sessionKey == nil ||
                      accepted.sessionKey == isolatedSession else {
                    throw DevelopmentGatewayProbeError.unexpectedAcceptedSession
                }
                if syntheticAgentAbort {
                    // Provider ingress is observed BEFORE chat.abort. The
                    // held synthetic model cannot complete by itself, so
                    // approval alone or aborting a queued run is insufficient.
                    try await waitForSyntheticProviderIngress(
                        environment: env
                    )
                    recordStreamPhase("chat-provider-ingress", environment: env)
                }
                try await client.cancel(
                    runID: accepted.runId,
                    sessionKey: isolatedSession,
                    agentID: accepted.agentId
                )
                await client.finishUpdates(runID: accepted.runId)
                if syntheticAgentAbort {
                    recordStreamPhase("chat-abort-confirmed", environment: env)
                }
                await adapter.disconnect()
                print(#"{"abortConfirmed":true}"#)
                return
            }

            // Two sequential runs target the SAME real Gateway session.
            // Distinct IDs ensure one turn cannot borrow the other's events.
            var observedIDs = Set<UUID>()
            for _ in 0..<(syntheticAgentSession ? 2 : 1) {
                let interactionID = InteractionID()
                guard observedIDs.insert(interactionID.rawValue).inserted else {
                    throw DevelopmentGatewayProbeError.duplicateInteractionID
                }
                let responses = await adapter.responses(
                    for: AgentRequest(interactionID: interactionID, text: message)
                )
                var deltaCount = 0
                var terminalCount = 0
                for try await response in responses {
                    guard response.interactionID == interactionID else {
                        throw DevelopmentGatewayProbeError.unexpectedInteractionID
                    }
                    switch response {
                    case let .textDelta(_, text):
                        if !text.isEmpty { deltaCount += 1 }
                        recordStreamPhase("chat-delta", environment: env)
                        print(text, terminator: "")
                        fflush(stdout)
                    case .completed:
                        terminalCount += 1
                        recordStreamPhase("chat-terminal", environment: env)
                        print("")
                    case let .failed(_, error):
                        throw error
                    }
                }
                if requireDevelopmentEvidence {
                    guard deltaCount > 0 else {
                        throw DevelopmentGatewayProbeError.missingIncrementalOutput
                    }
                    guard terminalCount == 1 else {
                        throw DevelopmentGatewayProbeError.missingTerminalCompletion
                    }
                }
            }
            if syntheticAgentSession {
                recordStreamPhase("chat-two-turns-completed", environment: env)
            }
            await adapter.disconnect()
        } catch let OpenClawHandshakeError.pairingRequired(pairing) {
            recordStreamPhase("pairing-required", environment: env)
            await adapter.disconnect()
            var lines = [
                "OpenClaw mutating validation identity requires its own pairing approval.",
                "The read-only health probe identity is intentionally separate and does not authorize this profile."
            ]
            if let requestID = pairing.requestID {
                lines.append("requestId: \(requestID)")
                lines.append("Review the pending request using the local OpenClaw device administration CLI.")
            }
            fail(lines.joined(separator: "\n"), code: 3)
        } catch {
            recordStreamFailure(error, environment: env)
            await adapter.disconnect()
            fail("OpenClaw chat probe failed (details redacted)", code: 1)
        }
    }

    /// Test-only fixed-vocabulary phase labels. This path is restricted to
    /// a generated 0700 real-Gateway temp directory, never user sessions.
    private static func recordStreamPhase(
        _ value: String, environment: [String: String]
    ) {
        writeStreamDiagnostic(value, environment: environment,
                              key: "AWL_DEV_GATEWAY_PHASE_FILE", name: "probe-phase")
    }

    private static func recordStreamFailure(
        _ error: Error, environment: [String: String]
    ) {
        let category: String
        if let failure = error as? DevelopmentGatewayProbeError {
            switch failure {
            case .missingIncrementalOutput: category = "chat-no-delta"
            case .missingTerminalCompletion: category = "chat-no-terminal"
            case .unexpectedAcceptedSession: category = "chat-session-mismatch"
            case .missingSyntheticProviderIngress: category = "chat-provider-not-executing"
            case .duplicateInteractionID: category = "chat-duplicate-interaction"
            case .unexpectedInteractionID: category = "chat-interaction-mismatch"
            }
        } else {
            category = "chat-other-error"
        }
        writeStreamDiagnostic(category, environment: environment,
                              key: "AWL_DEV_GATEWAY_RESULT_FILE", name: "probe-result")
    }

    private static func writeStreamDiagnostic(
        _ value: String, environment: [String: String],
        key: String, name: String
    ) {
        guard environment["AWL_DEV_GATEWAY_EXPECT_AGENT_STREAM"] == "1"
                || environment["AWL_DEV_GATEWAY_EXPECT_AGENT_ABORT"] == "1"
                || environment["AWL_DEV_GATEWAY_EXPECT_AGENT_SESSION"] == "1",
              environment["AWL_ALLOW_DEV_GATEWAY_TEST"] == "1",
              environment["AWL_OPENCLAW_EXPOSURE"] == "loopback",
              let state = environment["OPENCLAW_STATE_DIR"],
              let resultPath = environment[key],
              URL(fileURLWithPath: resultPath).standardizedFileURL.path ==
                URL(fileURLWithPath: state).deletingLastPathComponent()
                    .appendingPathComponent(name).standardizedFileURL.path else {
            return
        }
        try? value.write(toFile: resultPath, atomically: true, encoding: .utf8)
    }

    /// Bounded check of the locally owned upstream mock's aggregate ingress
    /// counter. The strict abort policy already validated this numeric port;
    /// we do not fetch a URL from the Gateway or expose any request content.
    private static func waitForSyntheticProviderIngress(
        environment: [String: String]
    ) async throws {
        guard let raw = environment["AWL_DEV_GATEWAY_MODEL_PORT"],
              let port = Int(raw), (1...65535).contains(port),
              String(port) == raw,
              let url = URL(string: "http://127.0.0.1:\(port)/health")
        else { throw DevelopmentGatewayProbeError.missingSyntheticProviderIngress }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1
        configuration.timeoutIntervalForResource = 2
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        for _ in 0..<80 {
            if let (data, response) = try? await session.data(from: url),
               (response as? HTTPURLResponse)?.statusCode == 200,
               data.count <= 8192,
               let object = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any],
               let requests = object["requests"] as? [String: Any],
               let ingress = requests["ingress"] as? [String: Any],
               let count = ingress["responses"] as? Int,
               count > 0 {
                return
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw DevelopmentGatewayProbeError.missingSyntheticProviderIngress
    }

    private static func configuredEndpoint(
        environment: [String: String]
    ) -> OpenClawEndpoint {
        guard let rawURL = environment["AWL_OPENCLAW_URL"],
              let url = URL(string: rawURL),
              ["ws", "wss"].contains(url.scheme?.lowercased() ?? "") else {
            fail("AWL_OPENCLAW_URL must be a ws:// or wss:// Gateway URL.", code: 2)
        }

        if let rawExposure = nonEmpty(environment["AWL_OPENCLAW_EXPOSURE"]) {
            guard let exposure = OpenClawEndpoint.Exposure(
                rawValue: rawExposure.lowercased()
            ) else {
                fail("AWL_OPENCLAW_EXPOSURE must be loopback, tailnet-direct, tailnet-serve, or private-reverse-proxy.", code: 2)
            }
            do {
                return try OpenClawEndpoint(gatewayURL: url, exposure: exposure)
            } catch {
                fail("OpenClaw endpoint policy rejected the configuration: \(String(describing: error))", code: 2)
            }
        }

        if let loopback = try? OpenClawEndpoint(
            gatewayURL: url,
            exposure: .loopback
        ) {
            return loopback
        }

        fail("AWL_OPENCLAW_EXPOSURE is required for every non-loopback Gateway URL.", code: 2)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func fail(_ message: String, code: Int32) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        Darwin.exit(code)
    }
}

private enum DevelopmentGatewayProbeError: Error {
    case missingIncrementalOutput
    case missingTerminalCompletion
    case unexpectedAcceptedSession
    case missingSyntheticProviderIngress
    case duplicateInteractionID
    case unexpectedInteractionID
}
