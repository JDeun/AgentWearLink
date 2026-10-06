import Foundation

public struct OpenClawConnectCredentials: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let token: String?
    public let password: String?
    public let explicitDeviceToken: String?
    public let bootstrapToken: String?

    public var description: String { "OpenClawConnectCredentials(<redacted>)" }
    public var debugDescription: String { description }

    public init(
        token: String? = nil,
        password: String? = nil,
        explicitDeviceToken: String? = nil,
        bootstrapToken: String? = nil
    ) {
        self.token = token
        self.password = password
        self.explicitDeviceToken = explicitDeviceToken
        self.bootstrapToken = bootstrapToken
    }
}

public struct OpenClawAssembledConnect: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let params: OpenClawConnectParams
    public let identity: OpenClawDeviceIdentity
    public let storedCredential: OpenClawDeviceCredential?
    public let effectiveToken: String?
    public let usedBootstrapToken: Bool

    public var description: String { "OpenClawAssembledConnect(<redacted>)" }
    public var debugDescription: String { description }
}

public struct OpenClawConnectAssembler: Sendable {
    private let identityManager: OpenClawDeviceIdentityManager
    private let credentialStore: any OpenClawDeviceCredentialStore
    private let proofBuilder = OpenClawDeviceProofBuilder()

    public init(
        identityManager: OpenClawDeviceIdentityManager,
        credentialStore: any OpenClawDeviceCredentialStore
    ) {
        self.identityManager = identityManager
        self.credentialStore = credentialStore
    }

    public func assemble(
        version: String,
        scopes requestedScopes: [String],
        credentials: OpenClawConnectCredentials,
        challenge: OpenClawConnectChallenge,
        clientIdentity: OpenClawGatewayClientIdentity = .backend,
        locale: String = "en-US"
    ) async throws -> OpenClawAssembledConnect {
        let identity = try await identityManager.loadOrCreate()
        let deviceID = try identity.deviceID
        let stored = try await credentialStore.load(
            deviceID: deviceID,
            role: "operator"
        )

        // Mirrors OpenClaw connect auth precedence.
        let effectiveToken =
            credentials.token ??
            credentials.explicitDeviceToken ??
            stored?.token

        let bootstrap = effectiveToken == nil
            ? credentials.bootstrapToken
            : nil

        let scopes: [String]
        if credentials.token == nil,
           credentials.explicitDeviceToken == nil,
           effectiveToken == stored?.token,
           let stored {
            scopes = stored.scopes
        } else {
            scopes = requestedScopes
        }

        let proof = try proofBuilder.makeProof(
            identity: identity,
            client: clientIdentity,
            scopes: scopes,
            token: effectiveToken,
            challenge: challenge
        )

        let auth = OpenClawConnectParams.Auth(
            token: effectiveToken,
            password: credentials.password,
            bootstrapToken: bootstrap
        )

        return OpenClawAssembledConnect(
            params: OpenClawConnectParams(
                version: version,
                clientIdentity: clientIdentity,
                scopes: scopes,
                auth: auth,
                locale: locale,
                device: proof
            ),
            identity: identity,
            storedCredential: stored,
            effectiveToken: effectiveToken,
            usedBootstrapToken: bootstrap != nil
        )
    }

    public func persistHello(
        _ hello: OpenClawHelloOK,
        assembled: OpenClawAssembledConnect
    ) async throws {
        guard let token = hello.auth.deviceToken else { return }

        let deviceID = try assembled.identity.deviceID
        let scopes: [String]

        if let stored = assembled.storedCredential,
           token == stored.token {
            // Preserve the approved grant for an unchanged stored token.
            scopes = stored.scopes
        } else {
            scopes = hello.auth.scopes
        }

        try await credentialStore.save(
            OpenClawDeviceCredential(
                deviceID: deviceID,
                role: hello.auth.role,
                scopes: scopes,
                token: token
            )
        )
    }
}
