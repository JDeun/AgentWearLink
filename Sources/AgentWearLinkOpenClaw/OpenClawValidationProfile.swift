import Foundation

public struct OpenClawValidationProfile: Sendable, Equatable {
    public let keychainService: String
    public let scopes: [String]
    public let clientIdentity: OpenClawGatewayClientIdentity

    public init(
        keychainService: String,
        scopes: [String],
        clientIdentity: OpenClawGatewayClientIdentity
    ) {
        self.keychainService = keychainService
        self.scopes = scopes
        self.clientIdentity = clientIdentity
    }

    /// Read-only connectivity/health validation identity.
    ///
    /// This profile is intentionally distinct from the mutating profile so a
    /// health check cannot silently acquire or reuse write-capable approval.
    public static let readOnly = Self(
        keychainService: "dev.agentwearlink.openclaw.probe",
        scopes: ["operator.read"],
        clientIdentity: .probe
    )

    /// Production-style validation identity for explicit harmless agent turns.
    ///
    /// It requires its own pairing/authorization and is the identity whose
    /// persisted credential reuse should be used as P0-B evidence.
    public static let mutating = Self(
        keychainService: "dev.agentwearlink.openclaw.chat-probe",
        scopes: ["operator.read", "operator.write"],
        clientIdentity: .backend
    )
}


/// This policy is only for a one-shot, unapproved identity rejection test.
/// It must never be used for approved pairing or persistent reconnect evidence.
/// Fail-closed admission for the read-only device-grant-only development probe.
/// A grant with write privileges may not silently ride a read-only profile.
public enum OpenClawReadOnlyGrantAdmission {
    public static func permits(_ credential: OpenClawDeviceCredential?) -> Bool {
        guard let credential,
              credential.role == "operator",
              credential.storageRole == "operator",
              !credential.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return Set(credential.scopes) == Set(["operator.read"])
    }
}

private enum OpenClawDevelopmentEphemeralProbeAdmission {
    static func permitsEphemeralIdentity(
        environment: [String: String],
        isLoopback: Bool,
        profile: OpenClawValidationProfile,
        expectedMarker: String,
        forbiddenMarker: String
    ) -> Bool {
        guard isLoopback,
              profile == .readOnly,
              environment[expectedMarker] == "1",
              environment[forbiddenMarker] == nil,
              ["AWL_DEV_GATEWAY_EXPECT_PAIRING", "AWL_DEV_GATEWAY_EXPECT_HEALTH_OK",
               "AWL_DEV_GATEWAY_EXPECT_GRANT_RECONNECT"]
                  .filter({ environment[$0] == "1" }).count == 1,
              (expectedMarker == "AWL_DEV_GATEWAY_EXPECT_GRANT_RECONNECT"
               || environment["AWL_DEV_GATEWAY_RECONNECT_STORED_ONLY"] == nil),
              environment["AWL_ALLOW_DEV_GATEWAY_TEST"] == "1",
              environment["AWL_OPENCLAW_EXPOSURE"] == "loopback",
              environment["AWL_DEV_GATEWAY_HEALTH_ONLY"] == "1",
              environment["AWL_DEV_GATEWAY_PROVE_ABORT"] == "0",
              environment["AWL_DEV_GATEWAY_USE_BUILT_PROBE"] == "1",
              environment["AWL_OPENCLAW_BOOTSTRAP_TOKEN"] == nil,
              let nonce = environment["AWL_DEV_KEYCHAIN_NONCE"],
              nonce.range(of: #"^[0-9a-f]{20}$"#, options: .regularExpression) != nil,
              let state = environment["OPENCLAW_STATE_DIR"],
              let url = environment["AWL_OPENCLAW_URL"],
              let components = URLComponents(string: url),
              components.scheme == "ws",
              components.host == "127.0.0.1",
              components.port != nil,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            return false
        }
        let path = URL(fileURLWithPath: state).standardizedFileURL
        return path.lastPathComponent == "state"
            && path.deletingLastPathComponent().lastPathComponent
                .hasPrefix("awl-real-dev-gateway-")
    }
}

public enum OpenClawDevelopmentNegativePairingPolicy {
    public static func permitsEphemeralIdentity(
        environment: [String: String], isLoopback: Bool,
        profile: OpenClawValidationProfile
    ) -> Bool {
        OpenClawDevelopmentEphemeralProbeAdmission.permitsEphemeralIdentity(
            environment: environment, isLoopback: isLoopback, profile: profile,
            expectedMarker: "AWL_DEV_GATEWAY_EXPECT_PAIRING",
            forbiddenMarker: "AWL_DEV_GATEWAY_EXPECT_HEALTH_OK"
        )
    }
}

/// Proves only real Gateway hello-ok and read-only health with ephemeral stores.
/// Persistent Keychain grants and tokenless reconnect are separately tested.
public enum OpenClawDevelopmentPositiveHealthPolicy {
    public static func permitsEphemeralIdentity(
        environment: [String: String], isLoopback: Bool,
        profile: OpenClawValidationProfile
    ) -> Bool {
        OpenClawDevelopmentEphemeralProbeAdmission.permitsEphemeralIdentity(
            environment: environment, isLoopback: isLoopback, profile: profile,
            expectedMarker: "AWL_DEV_GATEWAY_EXPECT_HEALTH_OK",
            forbiddenMarker: "AWL_DEV_GATEWAY_EXPECT_PAIRING"
        )
    }
}

/// Only for two sequential processes against the same disposable
/// localhost Gateway. Persisted data is removed with its private temp tree.
/// This is intentionally NOT Keychain, manual approval or Tailnet proof.
public enum OpenClawDevelopmentDisposableGrantPolicy {
    public static func permits(
        environment: [String: String],
        isLoopback: Bool,
        profile: OpenClawValidationProfile
    ) -> Bool {
        guard OpenClawDevelopmentEphemeralProbeAdmission.permitsEphemeralIdentity(
            environment: environment,
            isLoopback: isLoopback, profile: profile,
            expectedMarker: "AWL_DEV_GATEWAY_EXPECT_GRANT_RECONNECT",
            forbiddenMarker: "AWL_DEV_GATEWAY_EXPECT_PAIRING"
        ), environment["AWL_DEV_GATEWAY_EXPECT_HEALTH_OK"] == nil,
           let state = environment["OPENCLAW_STATE_DIR"],
           let raw = environment["AWL_DEV_GATEWAY_GRANT_STORE"],
           !raw.isEmpty, raw.hasPrefix("/"),
           URL(fileURLWithPath: raw).standardizedFileURL.path ==
             URL(fileURLWithPath: state).deletingLastPathComponent()
                 .appendingPathComponent("grant-cache").standardizedFileURL.path
        else { return false }

        let second = environment["AWL_DEV_GATEWAY_RECONNECT_STORED_ONLY"] == "1"
        guard environment["AWL_DEV_GATEWAY_RECONNECT_STORED_ONLY"] == nil || second else {
            return false
        }
        if second {
            return environment["AWL_OPENCLAW_TOKEN"] == nil
                || environment["AWL_OPENCLAW_TOKEN"] == ""
        }
        return environment["AWL_OPENCLAW_TOKEN"]?.isEmpty == false
    }
}

/// A deterministic synthetic-model test of the *real* OpenClaw Gateway's
/// mutating native-agent stream, restricted to a private disposable loopback
/// process. An unapproved physical/personal Gateway cannot opt into this.
public enum OpenClawDevelopmentAgentStreamPolicy {
    public static func permits(
        environment: [String: String],
        isLoopback: Bool,
        profile: OpenClawValidationProfile
    ) -> Bool {
        guard isLoopback, profile == .mutating,
              environment["AWL_DEV_GATEWAY_EXPECT_AGENT_STREAM"] == "1",
              environment["AWL_DEV_GATEWAY_EXPECT_PAIRING"] == nil,
              environment["AWL_DEV_GATEWAY_EXPECT_HEALTH_OK"] == nil,
              environment["AWL_DEV_GATEWAY_EXPECT_GRANT_RECONNECT"] == nil,
              environment["AWL_DEV_GATEWAY_EXPECT_AGENT_SESSION"] == nil,
              environment["AWL_DEV_GATEWAY_EXPECT_AGENT_ABORT"] == nil,
              environment["AWL_DEV_GATEWAY_SESSION_ASSERT"] == nil,
              environment["AWL_DEV_GATEWAY_RECONNECT_STORED_ONLY"] == nil,
              environment["AWL_ALLOW_DEV_GATEWAY_TEST"] == "1",
              environment["AWL_ALLOW_MUTATING_PROBE"] == "1",
              environment["AWL_DEV_GATEWAY_ASSERT"] == "1",
              environment["AWL_DEV_GATEWAY_USE_BUILT_PROBE"] == "1",
              environment["AWL_DEV_GATEWAY_HEALTH_ONLY"] == "0",
              environment["AWL_DEV_GATEWAY_PROVE_ABORT"] == "0",
              environment["AWL_OPENCLAW_EXPOSURE"] == "loopback",
              environment["AWL_OPENCLAW_BOOTSTRAP_TOKEN"] == nil,
              environment["AWL_OPENCLAW_CHAT_MESSAGE"] ==
                "AWL isolated integration check: reply with one short sentence.",
              let token = environment["AWL_OPENCLAW_TOKEN"], !token.isEmpty,
              let nonce = environment["AWL_DEV_KEYCHAIN_NONCE"],
              nonce.range(of: #"^[0-9a-f]{20}$"#, options: .regularExpression) != nil,
              let state = environment["OPENCLAW_STATE_DIR"],
              let url = environment["AWL_OPENCLAW_URL"],
              let components = URLComponents(string: url),
              components.scheme == "ws",
              components.host == "127.0.0.1",
              components.port != nil,
              components.path.isEmpty || components.path == "/",
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            return false
        }
        let path = URL(fileURLWithPath: state).standardizedFileURL
        return path.lastPathComponent == "state"
            && path.deletingLastPathComponent().lastPathComponent
                .hasPrefix("awl-real-dev-gateway-")
    }
}

/// Proves a *real, already executing* Gateway run can be remotely aborted.
/// Derive from the previously audited disposable agent-stream admission,
/// adding an explicit held-model abort marker and numeric mock port.
public enum OpenClawDevelopmentAgentAbortPolicy {
    public static func permits(
        environment: [String: String],
        isLoopback: Bool,
        profile: OpenClawValidationProfile
    ) -> Bool {
        guard environment["AWL_DEV_GATEWAY_EXPECT_AGENT_ABORT"] == "1",
              environment["AWL_DEV_GATEWAY_EXPECT_AGENT_STREAM"] == nil,
              environment["AWL_DEV_GATEWAY_ABORT_ASSERT"] == "1",
              environment["AWL_DEV_GATEWAY_PROVE_ABORT"] == "1",
              let rawPort = environment["AWL_DEV_GATEWAY_MODEL_PORT"],
              let port = Int(rawPort), (1...65535).contains(port),
              String(port) == rawPort else {
            return false
        }
        var scoped = environment
        scoped.removeValue(forKey: "AWL_DEV_GATEWAY_EXPECT_AGENT_ABORT")
        scoped.removeValue(forKey: "AWL_DEV_GATEWAY_ABORT_ASSERT")
        scoped.removeValue(forKey: "AWL_DEV_GATEWAY_MODEL_PORT")
        scoped["AWL_DEV_GATEWAY_EXPECT_AGENT_STREAM"] = "1"
        scoped["AWL_DEV_GATEWAY_PROVE_ABORT"] = "0"
        return OpenClawDevelopmentAgentStreamPolicy.permits(
            environment: scoped, isLoopback: isLoopback, profile: profile
        )
    }
}

/// Only two sequential, distinct interaction IDs through the production
/// native agent adapter, bound to the same disposable real Gateway session.
public enum OpenClawDevelopmentAgentSessionPolicy {
    public static func permits(
        environment: [String: String],
        isLoopback: Bool,
        profile: OpenClawValidationProfile
    ) -> Bool {
        guard environment["AWL_DEV_GATEWAY_EXPECT_AGENT_SESSION"] == "1",
              environment["AWL_DEV_GATEWAY_SESSION_ASSERT"] == "1",
              environment["AWL_DEV_GATEWAY_EXPECT_AGENT_STREAM"] == nil,
              environment["AWL_DEV_GATEWAY_EXPECT_AGENT_ABORT"] == nil,
              environment["AWL_DEV_GATEWAY_ABORT_ASSERT"] == nil,
              let rawPort = environment["AWL_DEV_GATEWAY_MODEL_PORT"],
              let port = Int(rawPort), (1...65535).contains(port),
              String(port) == rawPort,
              let session = environment["AWL_OPENCLAW_SESSION_KEY"],
              session.range(
                  of: #"^agent:[A-Za-z0-9_-]+:awl-dev-[A-Za-z0-9_-]+$"#,
                  options: .regularExpression
              ) != nil else { return false }
        var scoped = environment
        scoped.removeValue(forKey: "AWL_DEV_GATEWAY_EXPECT_AGENT_SESSION")
        scoped.removeValue(forKey: "AWL_DEV_GATEWAY_SESSION_ASSERT")
        scoped.removeValue(forKey: "AWL_DEV_GATEWAY_MODEL_PORT")
        scoped["AWL_DEV_GATEWAY_EXPECT_AGENT_STREAM"] = "1"
        return OpenClawDevelopmentAgentStreamPolicy.permits(
            environment: scoped, isLoopback: isLoopback, profile: profile
        )
    }
}

public enum OpenClawDevelopmentKeychainIsolationError: Error, Sendable {
    case invalidConfiguration
}

/// Opt-in, per-invocation Keychain identity partition for a disposable REAL
/// development Gateway. Never alters the production profile or Tailnet grant.
public enum OpenClawDevelopmentKeychainIsolation {
    public static func service(
        for profile: OpenClawValidationProfile,
        environment: [String: String],
        isLoopback: Bool
    ) throws -> String {
        guard let nonce = environment["AWL_DEV_KEYCHAIN_NONCE"] else {
            return profile.keychainService
        }
        let readOnly = profile.keychainService
            == OpenClawValidationProfile.readOnly.keychainService
        let mutating = profile.keychainService
            == OpenClawValidationProfile.mutating.keychainService
        guard environment["AWL_ALLOW_DEV_GATEWAY_TEST"] == "1",
              isLoopback,
              readOnly || mutating,
              nonce.range(
                of: #"^[0-9a-f]{20}$"#,
                options: .regularExpression
              ) != nil else {
            throw OpenClawDevelopmentKeychainIsolationError.invalidConfiguration
        }
        return "dev.agentwearlink.openclaw.isolated."
            + nonce + (readOnly ? ".read" : ".write")
    }
}
