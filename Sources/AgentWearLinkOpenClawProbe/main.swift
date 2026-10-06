import AgentWearLinkOpenClaw
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
        let supervisor = OpenClawGatewaySupervisor(
            connection: connection,
            dispatcher: dispatcher,
            state: state,
            socket: socket,
            appVersion: "0.1.0-probe",
            scopes: ["operator.read"],
            credentials: .init(
                token: token,
                bootstrapToken: bootstrapToken
            )
        )

        do {
            try await supervisor.start()

            let response = try await dispatcher.request(
                method: "health",
                params: EmptyParams()
            )

            guard response.ok else {
                fail(
                    "Gateway health RPC failed: \(response.error?.code ?? "UNKNOWN")",
                    code: 1
                )
            }

            if let payload = response.payload,
               let data = try? JSONEncoder().encode(payload),
               let json = String(data: data, encoding: .utf8) {
                print(json)
            } else {
                print(#"{"ok":true}"#)
            }

            await supervisor.stop()
        } catch let OpenClawHandshakeError.pairingRequired(pairing) {
            await supervisor.stop()
            var lines = [
                "OpenClaw device pairing is required."
            ]
            if let requestID = pairing.requestID {
                lines.append("requestId: \(requestID)")
                lines.append("Approve on the Mac mini: openclaw devices approve \(requestID)")
            }
            if let reason = pairing.reason {
                lines.append("reason: \(reason)")
            }
            fail(lines.joined(separator: "\n"), code: 3)
        } catch {
            await supervisor.stop()
            fail("OpenClaw probe failed: \(String(describing: error))", code: 1)
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func fail(_ message: String, code: Int32) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        Foundation.exit(code)
    }
}

private struct EmptyParams: Encodable, Sendable {}
