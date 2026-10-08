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
