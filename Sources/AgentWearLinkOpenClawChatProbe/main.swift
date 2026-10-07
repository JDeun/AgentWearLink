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

        let socket: URLSessionOpenClawWebSocket
        do {
            socket = try URLSessionOpenClawWebSocket(endpoint: endpoint)
        } catch {
            fail("Invalid OpenClaw WebSocket endpoint: \(String(describing: error))", code: 2)
        }

        let state = OpenClawGatewayState()
        let assembler = OpenClawConnectAssembler(
            identityManager: .init(
                store: KeychainOpenClawDeviceIdentityStore(
                    service: profile.keychainService
                )
            ),
            credentialStore: KeychainOpenClawDeviceCredentialStore(
                service: profile.keychainService
            ),
            gatewayNamespace: endpoint.credentialNamespace,
            bootstrapHandoffPersistenceAllowed:
                endpoint.allowsBootstrapHandoffPersistence
        )
        let connection = OpenClawGatewayConnection(socket: socket, assembler: assembler, state: state)
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
        let id = InteractionID()

        do {
            try await adapter.connect()
            let responses = await adapter.responses(for: AgentRequest(interactionID: id, text: message))
            for try await response in responses {
                switch response {
                case let .textDelta(_, text):
                    print(text, terminator: "")
                    fflush(stdout)
                case .completed:
                    print("")
                case let .failed(_, error):
                    throw error
                }
            }
            await adapter.disconnect()
        } catch let OpenClawHandshakeError.pairingRequired(pairing) {
            await adapter.disconnect()
            var lines = [
                "OpenClaw mutating validation identity requires its own pairing approval.",
                "The read-only health probe identity is intentionally separate and does not authorize this profile."
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
            await adapter.disconnect()
            fail("OpenClaw chat probe failed: \(String(describing: error))", code: 1)
        }
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
