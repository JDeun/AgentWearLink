import AgentWearLinkCore
import AgentWearLinkOpenClaw
import Foundation

/// One Gateway connection: supervisor + dispatcher over one socket.
struct GatewaySession: Sendable {
    let supervisor: OpenClawGatewaySupervisor
    let dispatcher: OpenClawRPCDispatcher
    let state: OpenClawGatewayState
    let usedStoredGrant: Bool

    func connectionState() async -> GatewayConnectionState {
        await state.connectionState
    }

    func health() async throws {
        let response = try await dispatcher.request(method: "health", params: EmptyParams())
        guard response.ok else {
            throw AWLOpenClawError.gateway(code: "UNAVAILABLE", retryable: true)
        }
    }

    func agentName(sessionKey: String?) async -> String? {
        let identity = try? await OpenClawAgentRunClient(dispatcher: dispatcher)
            .identity(sessionKey: sessionKey)
        return identity?.displayName
    }
}

private struct EmptyParams: Encodable, Sendable {}

/// Keychain-backed device identity and the approved, endpoint-scoped device
/// grant. Tokens never leave the Keychain stores; nothing here is logged.
struct GatewayLink: Sendable {
    static let keychainService = "dev.agentwearlink.companion.openclaw"
    static let appVersion = "0.1.0-companion"
    static let scopes = ["operator.read", "operator.write"]

    private let identityStore = KeychainOpenClawDeviceIdentityStore(service: keychainService)
    private let credentialStore = KeychainOpenClawDeviceCredentialStore(service: keychainService)

    /// This iPhone's device id (created on first use, kept in the Keychain).
    func deviceID() async throws -> String {
        try await OpenClawDeviceIdentityManager(store: identityStore).loadOrCreate().deviceID
    }

    /// Whether a write-capable grant for this endpoint is stored. Never
    /// infers authorization from an identity alone; does not touch the network.
    func grantStatus(for endpoint: OpenClawEndpoint) async -> GrantStatus {
        let scoped = GatewayScopedOpenClawDeviceCredentialStore(
            base: credentialStore,
            namespace: endpoint.credentialNamespace
        )
        do {
            guard let identity = try await identityStore.load() else { return .missing }
            let grant = try await scoped.load(deviceID: identity.deviceID, role: "operator")
            return OpenClawStoredGrantAdmission.permitsWriteRuntime(grant) ? .approved : .missing
        } catch {
            // Typically errSecInteractionNotAllowed before the first unlock
            // after a reboot: unknown, not revoked.
            return .unavailable
        }
    }

    /// "승인만 다시 받기": drop the stored grant, keep the identity.
    func forgetGrant(for endpoint: OpenClawEndpoint) async {
        let scoped = GatewayScopedOpenClawDeviceCredentialStore(
            base: credentialStore,
            namespace: endpoint.credentialNamespace
        )
        guard let identity = try? await identityStore.load(),
              let deviceID = try? identity.deviceID else { return }
        try? await scoped.remove(deviceID: deviceID, role: "operator")
    }

    /// "모두 지우고 처음부터": also replace the device identity, so the
    /// Gateway sees a brand-new device with a new fingerprint.
    func forgetEverything(endpoint: OpenClawEndpoint?) async {
        if let endpoint { await forgetGrant(for: endpoint) }
        try? await identityStore.save(OpenClawDeviceIdentity.generate())
    }

    func makeSession(
        endpoint: OpenClawEndpoint,
        credentials: OpenClawConnectCredentials,
        diagnostics: AWLDiagnosticRecorder?
    ) throws -> GatewaySession {
        let socket = try URLSessionOpenClawWebSocket(endpoint: endpoint)
        let state = OpenClawGatewayState()
        let assembler = OpenClawConnectAssembler(
            identityManager: .init(store: identityStore),
            credentialStore: credentialStore,
            gatewayNamespace: endpoint.credentialNamespace,
            bootstrapHandoffPersistenceAllowed: endpoint.allowsBootstrapHandoffPersistence
        )
        let connection = OpenClawGatewayConnection(socket: socket, assembler: assembler, state: state)
        let dispatcher = OpenClawRPCDispatcher(socket: socket, state: state)
        let supervisor = OpenClawGatewaySupervisor(
            connection: connection,
            dispatcher: dispatcher,
            state: state,
            socket: socket,
            appVersion: Self.appVersion,
            scopes: Self.scopes,
            credentials: credentials,
            clientIdentity: .backend,
            locale: Locale.preferredLanguages.first ?? "ko-KR",
            diagnostics: diagnostics
        )
        let usedStoredGrant = credentials.token == nil && credentials.bootstrapToken == nil
            && credentials.password == nil && credentials.explicitDeviceToken == nil
        return GatewaySession(
            supervisor: supervisor, dispatcher: dispatcher, state: state, usedStoredGrant: usedStoredGrant
        )
    }
}
