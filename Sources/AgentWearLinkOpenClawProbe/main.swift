import AgentWearLinkOpenClaw
import Darwin
import Foundation

@main
struct AgentWearLinkOpenClawProbe {
    static func main() async {
        let environment = ProcessInfo.processInfo.environment

        guard let rawURL = environment["AWL_OPENCLAW_URL"],
              let url = URL(string: rawURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "ws" || scheme == "wss" else {
            fail("""
            AWL_OPENCLAW_URL must be a ws:// or wss:// Gateway URL.
            Prefer wss://<mac-mini>.ts.net when using Tailscale Serve.
            """, code: 2)
        }

        let token = nonEmpty(environment["AWL_OPENCLAW_TOKEN"])
        let bootstrapToken = nonEmpty(environment["AWL_OPENCLAW_BOOTSTRAP_TOKEN"])
        let agentPrompt = nonEmpty(environment["AWL_OPENCLAW_AGENT_PROMPT"])
        let sessionKey = nonEmpty(environment["AWL_OPENCLAW_SESSION_KEY"])
        let agentID = nonEmpty(environment["AWL_OPENCLAW_AGENT_ID"])

        if agentPrompt != nil && sessionKey == nil {
            fail(
                "AWL_OPENCLAW_SESSION_KEY is required for agent smoke mode so an accepted run can be correlated and cancelled safely.",
                code: 2
            )
        }

        let socket = URLSessionOpenClawWebSocket(url: url)
        let state = OpenClawGatewayState()
        let identityStore = KeychainOpenClawDeviceIdentityStore(
            service: "dev.agentwearlink.openclaw.probe"
        )
        let credentialStore = KeychainOpenClawDeviceCredentialStore(
            service: "dev.agentwearlink.openclaw.probe"
        )
        let assembler = OpenClawConnectAssembler(
            identityManager: .init(store: identityStore),
            credentialStore: credentialStore
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
        let scopes = agentPrompt == nil
            ? ["operator.read"]
            : ["operator.read", "operator.write"]
        let supervisor = OpenClawGatewaySupervisor(
            connection: connection,
            dispatcher: dispatcher,
            state: state,
            socket: socket,
            appVersion: "0.1.0-probe",
            scopes: scopes,
            credentials: .init(
                token: token,
                bootstrapToken: bootstrapToken
            )
        )

        var acceptedRunID: String?

        do {
            try await supervisor.start()

            let health = try await dispatcher.request(
                method: "health",
                params: EmptyParams()
            )
            guard health.ok else {
                fail(
                    "Gateway health RPC failed: \(health.error?.code ?? "UNKNOWN")",
                    code: 1
                )
            }

            guard let agentPrompt, let sessionKey else {
                printJSON(health.payload ?? .object(["ok": .bool(true)]))
                await supervisor.stop()
                return
            }

            writeDiagnostic("Gateway health succeeded; starting explicit agent smoke run.")

            let events = await dispatcher.events()
            let runClient = OpenClawAgentRunClient(dispatcher: dispatcher)
            let accepted = try await runClient.submit(
                message: agentPrompt,
                agentID: agentID,
                sessionKey: sessionKey,
                deliver: false,
                idempotencyKey: UUID().uuidString
            )
            acceptedRunID = accepted.runId
            writeDiagnostic("accepted runId: \(accepted.runId)")

            let updates = await runClient.updates(
                from: events,
                runID: accepted.runId
            )
            let streamTask = Task {
                do {
                    for try await update in updates {
                        if case let .assistant(_, payload) = update,
                           let delta = textDelta(from: payload) {
                            writeDiagnostic("delta: \(delta)")
                        }
                    }
                } catch {
                    writeDiagnostic(
                        "agent event stream ended: \(String(describing: error))"
                    )
                }
            }

            let terminal = try await waitUntilTerminal(
                client: runClient,
                runID: accepted.runId
            )
            streamTask.cancel()

            guard terminal.status == "ok" else {
                let detail = terminal.error
                    ?? terminal.stopReason
                    ?? terminal.status
                await supervisor.stop()
                fail(
                    "Agent run \(accepted.runId) ended with \(detail).",
                    code: 4
                )
            }

            printJSON(
                .object([
                    "ok": .bool(true),
                    "runId": .string(accepted.runId),
                    "status": .string(terminal.status),
                    "terminalReply": terminal.terminalReply ?? .null,
                    "terminalReceipt": terminal.terminalReceipt ?? .null
                ])
            )
            await supervisor.stop()
        } catch let OpenClawHandshakeError.pairingRequired(pairing) {
            await supervisor.stop()
            var lines = [
                "OpenClaw device pairing is required."
            ]
            if let requestID = pairing.requestID {
                lines.append("requestId: \(requestID)")
                lines.append(
                    "Approve on the Mac mini: openclaw devices approve \(requestID)"
                )
            }
            if let reason = pairing.reason {
                lines.append("reason: \(reason)")
            }
            fail(lines.joined(separator: "\n"), code: 3)
        } catch {
            await supervisor.stop()
            var message = "OpenClaw probe failed: \(String(describing: error))"
            if let acceptedRunID {
                message += "\naccepted runId: \(acceptedRunID)"
                message += "\nThe probe will not resubmit this turn automatically."
            }
            fail(message, code: 1)
        }
    }

    private static func waitUntilTerminal(
        client: OpenClawAgentRunClient,
        runID: String
    ) async throws -> OpenClawAgentWaitResult {
        while true {
            let result = try await client.wait(
                runID: runID,
                timeoutMilliseconds: 30_000
            )
            switch result.status {
            case "pending", "timeout":
                continue
            default:
                return result
            }
        }
    }

    private static func textDelta(from value: JSONValue?) -> String? {
        guard case let .object(object)? = value else { return nil }
        for key in ["delta", "text"] {
            if case let .string(text)? = object[key], !text.isEmpty {
                return text
            }
        }
        return nil
    }

    private static func printJSON(_ value: JSONValue) {
        guard let data = try? JSONEncoder().encode(value),
              let json = String(data: data, encoding: .utf8) else {
            print(#"{"ok":true}"#)
            return
        }
        print(json)
    }

    private static func writeDiagnostic(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func fail(_ message: String, code: Int32) -> Never {
        writeDiagnostic(message)
        Darwin.exit(code)
    }
}

private struct EmptyParams: Encodable, Sendable {}
