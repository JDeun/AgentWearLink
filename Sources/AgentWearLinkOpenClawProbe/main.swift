import AgentWearLinkOpenClaw
import Foundation
import Darwin

@main
struct AgentWearLinkOpenClawProbe {
    static func main() async {
        let environment = ProcessInfo.processInfo.environment
        let endpoint = configuredEndpoint(environment: environment)

        let token = nonEmpty(environment["AWL_OPENCLAW_TOKEN"])
        let bootstrapToken = nonEmpty(environment["AWL_OPENCLAW_BOOTSTRAP_TOKEN"])

        let socket: URLSessionOpenClawWebSocket
        do {
            socket = try URLSessionOpenClawWebSocket(endpoint: endpoint)
        } catch {
            fail("Invalid OpenClaw WebSocket endpoint: \(String(describing: error))", code: 2)
        }

        let state = OpenClawGatewayState()
        let identityStore = KeychainOpenClawDeviceIdentityStore(
            service: "dev.agentwearlink.openclaw.probe"
        )
        let credentialStore = KeychainOpenClawDeviceCredentialStore(
            service: "dev.agentwearlink.openclaw.probe"
        )
        let assembler = OpenClawConnectAssembler(
            identityManager: .init(store: identityStore),
            credentialStore: credentialStore,
            gatewayNamespace: endpoint.credentialNamespace,
            bootstrapHandoffPersistenceAllowed: endpoint.allowsBootstrapHandoffPersistence
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
            ),
            clientIdentity: .probe
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

    private static func configuredEndpoint(
        environment: [String: String]
    ) -> OpenClawEndpoint {
        guard let rawURL = environment["AWL_OPENCLAW_URL"],
              let url = URL(string: rawURL),
              ["ws", "wss"].contains(url.scheme?.lowercased() ?? "") else {
            fail("""
            AWL_OPENCLAW_URL must be a ws:// or wss:// Gateway URL.
            Prefer wss://<mac-mini>.ts.net when using Tailscale Serve.
            """, code: 2)
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

private struct EmptyParams: Encodable, Sendable {}
