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
        // The unapproved-device rejection test deliberately has no persisted
        // grant. Headless macOS runners may stall on Keychain dialogs, so
        // the CI-only negative probe uses disposable in-memory stores.
        // Operator-approved and tokenless-reuse probes retain real Keychain.
        let ephemeralNegativePairing = environment["AWL_DEV_GATEWAY_EXPECT_PAIRING"] == "1"
        let ephemeralPositiveHealth = environment["AWL_DEV_GATEWAY_EXPECT_HEALTH_OK"] == "1"
        if ephemeralNegativePairing {
            guard OpenClawDevelopmentNegativePairingPolicy.permitsEphemeralIdentity(
                environment: environment,
                isLoopback: endpoint.exposure == .loopback,
                profile: profile
            ) else {
                fail("Negative pairing probe requires isolated loopback read-only state.", code: 2)
            }
        }
        if ephemeralPositiveHealth {
            guard OpenClawDevelopmentPositiveHealthPolicy.permitsEphemeralIdentity(
                environment: environment,
                isLoopback: endpoint.exposure == .loopback,
                profile: profile
            ) else {
                fail("Positive health probe requires isolated loopback read-only state.", code: 2)
            }
        }
        let ephemeralProbe = ephemeralNegativePairing || ephemeralPositiveHealth
        let disposableGrant = environment["AWL_DEV_GATEWAY_EXPECT_GRANT_RECONNECT"] == "1"
        if disposableGrant {
            guard OpenClawDevelopmentDisposableGrantPolicy.permits(
                environment: environment,
                isLoopback: endpoint.exposure == .loopback,
                profile: profile
            ) else {
                fail("Disposable device-grant contract requires isolated read-only state.", code: 2)
            }
        }
        // This fixture's disk store exists only under the Python harness's
        // private, disposable 0700 test directory. Production always uses
        // the real Keychain; other CI lanes use in-memory stores.
        let grantDirectory = URL(fileURLWithPath:
            environment["AWL_DEV_GATEWAY_GRANT_STORE"] ?? "/nonexistent"
        )
        let identityStore: any OpenClawDeviceIdentityStore
        let credentialStore: any OpenClawDeviceCredentialStore
        if disposableGrant {
            identityStore = DisposableProbeIdentityStore(directory: grantDirectory)
            credentialStore = DisposableProbeCredentialStore(directory: grantDirectory)
        } else if ephemeralProbe {
            identityStore = InMemoryOpenClawDeviceIdentityStore()
            credentialStore = InMemoryOpenClawDeviceCredentialStore()
        } else {
            identityStore = KeychainOpenClawDeviceIdentityStore(service: keychainService)
            credentialStore = KeychainOpenClawDeviceCredentialStore(service: keychainService)
        }
        // This explicit second-process acceptance test must never present
        // the shared Gateway token or bootstrap handoff. It must use the
        // scoped server-approved device grant already saved in Keychain.
        let grantOnlyReconnect = environment["AWL_DEV_GATEWAY_RECONNECT_STORED_ONLY"] == "1"
        if grantOnlyReconnect {
            guard environment["AWL_ALLOW_DEV_GATEWAY_TEST"] == "1",
                  endpoint.exposure == .loopback,
                  environment["AWL_DEV_KEYCHAIN_NONCE"] != nil,
                  bootstrapToken == nil,
                  !ephemeralProbe,
                  (!disposableGrant ||
                   OpenClawDevelopmentDisposableGrantPolicy.permits(
                       environment: environment,
                       isLoopback: endpoint.exposure == .loopback,
                       profile: profile
                   )) else {
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
            state: state,
            progress: { phase in
                recordPhase(phase.rawValue, environment: environment)
            }
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
            recordPhase("handshake-started", environment: environment)
            try await supervisor.start()
            recordPhase("authenticated", environment: environment)

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
            recordPhase("health-accepted", environment: environment)
            print(#"{"ok":true}"#)

            await supervisor.stop()
        } catch let OpenClawHandshakeError.pairingRequired(pairing) {
            recordPhase("pairing-required", environment: environment)
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
            // Preserve the last successful wire milestone. Replacing it with
            // "probe-error" would hide whether assembly/send/reply succeeded.
            recordFailure(error, environment: environment)
            await supervisor.stop()
            fail("OpenClaw probe failed (details redacted)", code: 1)
        }
    }

    /// Only allowlisted diagnostic labels are written to disposable state.
    /// Raw frames, request IDs, signatures and tokens never enter these files.
    private static func recordPhase(
        _ phase: String, environment: [String: String]
    ) {
        recordDiagnostic(
            phase, environment: environment,
            key: "AWL_DEV_GATEWAY_PHASE_FILE", filename: "probe-phase"
        )
    }

    private static func recordFailure(
        _ error: Error, environment: [String: String]
    ) {
        let category: String
        if let handshake = error as? OpenClawHandshakeError {
            switch handshake {
            case .challengeTimeout: category = "challenge-timeout"
            case .helloTimeout: category = "hello-timeout"
            case .unexpectedConnectResponse: category = "unexpected-connect-response"
            case .challengeRequired: category = "challenge-required"
            case .invalidChallenge: category = "invalid-challenge"
            case .missingHello: category = "missing-hello"
            case .invalidPolicy: category = "invalid-policy"
            case .connectInvalidated: category = "connect-invalidated"
            default: category = "handshake-other"
            }
        } else if let gateway = error as? AWLOpenClawError {
            switch gateway {
            case let .gateway(code, _, _):
                switch code {
                case "AUTH_FAILED", "UNAUTHORIZED", "FORBIDDEN":
                    category = "gateway-auth-denied"
                case "INVALID_REQUEST": category = "gateway-invalid-request"
                case "PAIRING_REQUIRED": category = "gateway-pairing-code"
                case "DEVICE_TOKEN_REJECTED": category = "gateway-device-token-rejected"
                default: category = "gateway-other"
                }
            case .disconnected: category = "transport-disconnected"
            case .protocolMismatch: category = "protocol-mismatch"
            default: category = "gateway-state-error"
            }
        } else if error is OpenClawFrameError {
            category = "frame-invalid"
        } else if error is DecodingError {
            category = "decoding-failed"
        } else {
            category = "other-error"
        }
        recordDiagnostic(
            category, environment: environment,
            key: "AWL_DEV_GATEWAY_RESULT_FILE", filename: "probe-result"
        )
    }

    private static func recordDiagnostic(
        _ value: String, environment: [String: String],
        key: String, filename: String
    ) {
        // Diagnostics may be written only by one mutually exclusive
        // read-only disposable real-Gateway contract. Values are separately
        // classified into a hardcoded vocabulary and never carry raw frames.
        let contractCount = [
            "AWL_DEV_GATEWAY_EXPECT_PAIRING",
            "AWL_DEV_GATEWAY_EXPECT_HEALTH_OK",
            "AWL_DEV_GATEWAY_EXPECT_GRANT_RECONNECT"
        ].filter { environment[$0] == "1" }.count
        guard contractCount == 1,
              environment["AWL_ALLOW_DEV_GATEWAY_TEST"] == "1",
              environment["AWL_OPENCLAW_EXPOSURE"] == "loopback",
              let stateDir = environment["OPENCLAW_STATE_DIR"],
              let path = environment[key],
              URL(fileURLWithPath: path).standardizedFileURL.path ==
                URL(fileURLWithPath: stateDir).deletingLastPathComponent()
                    .appendingPathComponent(filename).standardizedFileURL.path
        else { return }
        try? value.write(toFile: path, atomically: true, encoding: .utf8)
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
