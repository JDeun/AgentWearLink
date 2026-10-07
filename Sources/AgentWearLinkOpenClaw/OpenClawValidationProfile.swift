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
