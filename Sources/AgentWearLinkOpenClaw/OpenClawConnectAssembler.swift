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
    /// Token bound into the V3 device proof. This is selected from the exact
    /// wire auth fields in protocol order: shared, device, then bootstrap.
    public let effectiveToken: String?
    public let usedStoredCredential: Bool
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

        // Mirrors upstream selectGatewayConnectAuth/buildGatewayConnectAuth
        // for the auth fields supported by AWL.
        let sharedToken = credentials.token
        let explicitDeviceToken = credentials.explicitDeviceToken
        let storedToken = stored?.token

        let resolvedDeviceToken: String?
        if let explicitDeviceToken {
            resolvedDeviceToken = explicitDeviceToken
        } else if sharedToken == nil,
                  credentials.password == nil,
                  (credentials.bootstrapToken == nil || storedToken != nil) {
            resolvedDeviceToken = storedToken
        } else {
            resolvedDeviceToken = nil
        }

        let usedStoredCredential =
            resolvedDeviceToken != nil &&
            explicitDeviceToken == nil &&
            storedToken != nil &&
            resolvedDeviceToken == storedToken

        let bootstrap =
            sharedToken == nil &&
            resolvedDeviceToken == nil &&
            credentials.password == nil
            ? credentials.bootstrapToken
            : nil

        // OpenClaw V3 binds exactly one token to the device proof in protocol
        // precedence order. Password is intentionally not a signature token.
        let effectiveToken =
            sharedToken ??
            resolvedDeviceToken ??
            bootstrap

        let scopes: [String]
        if usedStoredCredential,
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
            token: sharedToken,
            deviceToken: resolvedDeviceToken,
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
            usedStoredCredential: usedStoredCredential,
            usedBootstrapToken: bootstrap != nil
        )
    }


    /// Builds the one bounded recovery attempt explicitly requested by the
    /// Gateway's retry_with_device_token guidance. The retry uses only the
    /// previously approved device grant and its stored scopes.
    public func assembleStoredDeviceTokenRetry(
        version: String,
        challenge: OpenClawConnectChallenge,
        clientIdentity: OpenClawGatewayClientIdentity = .backend,
        locale: String = "en-US"
    ) async throws -> OpenClawAssembledConnect? {
        let identity = try await identityManager.loadOrCreate()
        let deviceID = try identity.deviceID
        guard let stored = try await credentialStore.load(
            deviceID: deviceID,
            role: "operator"
        ) else {
            return nil
        }

        let proof = try proofBuilder.makeProof(
            identity: identity,
            client: clientIdentity,
            scopes: stored.scopes,
            token: stored.token,
            challenge: challenge
        )
        let auth = OpenClawConnectParams.Auth(deviceToken: stored.token)

        return OpenClawAssembledConnect(
            params: OpenClawConnectParams(
                version: version,
                clientIdentity: clientIdentity,
                scopes: stored.scopes,
                auth: auth,
                locale: locale,
                device: proof
            ),
            identity: identity,
            storedCredential: stored,
            effectiveToken: stored.token,
            usedStoredCredential: true,
            usedBootstrapToken: false
        )
    }

    public func invalidateStoredCredentialIfUsed(
        _ assembled: OpenClawAssembledConnect
    ) async throws {
        guard assembled.usedStoredCredential,
              let stored = assembled.storedCredential else { return }

        _ = try await credentialStore.compareAndRemove(
            deviceID: stored.deviceID,
            role: stored.storageRole,
            expected: stored
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

        let credential = OpenClawDeviceCredential(
            deviceID: deviceID,
            role: hello.auth.role,
            requestedRole: assembled.params.role,
            scopes: scopes,
            token: token
        )

        // The stored credential captured during assemble() is the compare token.
        // A stale handshake must not overwrite a grant that a newer handshake
        // has already rotated after this snapshot was taken.
        _ = try await credentialStore.compareAndSave(
            credential,
            expected: assembled.storedCredential
        )
    }
}
