import AgentWearLinkOpenClaw
import Foundation
import Darwin

@main
struct AgentWearLinkOpenClawProbe {
    static func main() async {
        let environment = ProcessInfo.processInfo.environment
        let profile = OpenClawValidationProfile.readOnly
        let endpoint = configuredEndpoint(environment: environment)

        let token = nonEmpty(environment["AWL_OPENCLAW_TOKEN"])
        let bootstrapToken = nonEmpty(environment["AWL_OPENCLAW_BOOTSTRAP_TOKEN"])

        let keychainService: String
        do {
            keychainService = try OpenClawDevelopmentKeychainIsolation.service(
                for: profile,
                environment: environment,
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

        let state = OpenClawGatewayState()
        let identityStore = KeychainOpenClawDeviceIdentityStore(
            service: keychainService
        )
        let credentialStore = KeychainOpenClawDeviceCredentialStore(
            service: keychainService
        )
        // This explicit second-process acceptance test must never present
        // the shared Gateway token or bootstrap handoff. It must use the
        // scoped server-approved device grant already saved in Keychain.
        let grantOnlyReconnect = environment["AWL_DEV_GATEWAY_RECONNECT_STORED_ONLY"] == "1"
        if grantOnlyReconnect {
            guard environment["AWL_ALLOW_DEV_GATEWAY_TEST"] == "1",
                  endpoint.exposure == .loopback,
                  environment["AWL_DEV_KEYCHAIN_NONCE"] != nil,
                  bootstrapToken == nil else {
                fail("Device-grant reconnect requires isolated local development profile.", code: 2)
            }
            do {
                guard let identity = try await identityStore.load(),
                      let saved = try await GatewayScopedOpenClawDeviceCredentialStore(
                          base: credentialStore,
                          namespace: endpoint.credentialNamespace
                      ).load(deviceID: try identity.deviceID, role: "operator"),
                      OpenClawReadOnlyGrantAdmission.permits(saved) else {
                    fail("No approved read-only device grant for isolated reconnect.", code: 2)
                }
            } catch {
                fail("Stored read-only device grant could not be verified.", code: 2)
            }
        }
        let assembler = OpenClawConnectAssembler(
            identityManager: .init(store: identityStore),
            credentialStore: credentialStore,
            gatewayNamespace: endpoint.credentialNamespace,
            bootstrapHandoffPersistenceAllowed:
                endpoint.allowsBootstrapHandoffPersistence
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
            scopes: profile.scopes,
            credentials: .init(
                token: grantOnlyReconnect ? nil : token,
                bootstrapToken: grantOnlyReconnect ? nil : bootstrapToken
            ),
            clientIdentity: profile.clientIdentity
        )

        do {
            try await supervisor.start()

            let response = try await dispatcher.request(
                method: "health",
                params: EmptyParams()
            )

            guard response.ok else {
                fail("Gateway health RPC failed (details redacted)", code: 1)
            }

            // The upstream health payload is not a public diagnostic contract:
            // it may grow to contain addresses or sensitive local configuration.
            // Report an allowlisted success flag only; no raw Gateway JSON.
            print(#"{"ok":true}"#)

            await supervisor.stop()
        } catch let OpenClawHandshakeError.pairingRequired(pairing) {
            await supervisor.stop()
            var lines = [
                "OpenClaw device pairing is required."
            ]
            if let requestID = pairing.requestID {
                lines.append("requestId: \(requestID)")
                lines.append("Review the pending request using the local OpenClaw device administration CLI.")
            }
            fail(lines.joined(separator: "\n"), code: 3)
        } catch {
            await supervisor.stop()
            fail("OpenClaw probe failed (details redacted)", code: 1)
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
