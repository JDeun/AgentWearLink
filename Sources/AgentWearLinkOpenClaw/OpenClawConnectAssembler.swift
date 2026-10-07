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
    private static let maximumBootstrapHandoffTokens = 8

    private let identityManager: OpenClawDeviceIdentityManager
    private let credentialStore: any OpenClawDeviceCredentialStore
    private let bootstrapHandoffPersistenceAllowed: Bool
    private let proofBuilder = OpenClawDeviceProofBuilder()

    public init(
        identityManager: OpenClawDeviceIdentityManager,
        credentialStore: any OpenClawDeviceCredentialStore,
        gatewayNamespace: OpenClawGatewayCredentialNamespace? = nil,
        bootstrapHandoffPersistenceAllowed: Bool = false
    ) {
        self.identityManager = identityManager
        self.bootstrapHandoffPersistenceAllowed =
            bootstrapHandoffPersistenceAllowed
        if let gatewayNamespace {
            self.credentialStore = GatewayScopedOpenClawDeviceCredentialStore(
                base: credentialStore,
                namespace: gatewayNamespace
            )
        } else {
            // Source-compatible fallback for callers that have not yet bound
            // their store to a validated Gateway endpoint. Production
            // composition should always provide a namespace.
            self.credentialStore = credentialStore
        }
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
        let deviceID = try assembled.identity.deviceID
        let handoffGrants = normalizedBootstrapHandoffGrants(
            hello.auth.deviceTokens ?? []
        )
        let mayPersistHandoffs =
            assembled.usedBootstrapToken &&
            bootstrapHandoffPersistenceAllowed
        let requestedRoleHandoff = mayPersistHandoffs
            ? handoffGrants.last(where: { $0.role == assembled.params.role })
            : nil

        if let token = hello.auth.deviceToken {
            let scopes: [String]
            if let stored = assembled.storedCredential,
               token == stored.token {
                // Preserve the approved grant for an unchanged stored token.
                scopes = stored.scopes
            } else {
                scopes = hello.auth.scopes
            }

            // When a trusted bootstrap response also hands off a token for the
            // same requested role, keep the primary reconnect token in its own
            // partition so the operator handoff can occupy the normal lookup
            // key used by the next operator connection.
            let primaryStorageOverride = requestedRoleHandoff == nil
                ? nil
                : Self.bootstrapPrimaryStorageRole(
                    requestedRole: assembled.params.role
                )

            let credential = OpenClawDeviceCredential(
                deviceID: deviceID,
                role: hello.auth.role,
                requestedRole: assembled.params.role,
                storageRoleOverride: primaryStorageOverride,
                scopes: scopes,
                token: token
            )

            let expected = primaryStorageOverride == nil
                ? assembled.storedCredential
                : nil

            // A stale handshake cannot overwrite a newer grant. A separately
            // partitioned bootstrap-primary record is insert-only.
            _ = try await credentialStore.compareAndSave(
                credential,
                expected: expected
            )
        }

        guard mayPersistHandoffs else { return }

        for grant in handoffGrants {
            let credential = OpenClawDeviceCredential(
                deviceID: deviceID,
                role: grant.role,
                requestedRole: grant.role,
                scopes: grant.scopes,
                token: grant.token
            )

            // The requested operator slot is the same snapshot loaded during
            // assemble(). Other handoff roles are insert-only because this
            // handshake did not read their prior state.
            let expected = grant.role == assembled.params.role
                ? assembled.storedCredential
                : nil

            _ = try await credentialStore.compareAndSave(
                credential,
                expected: expected
            )
        }
    }

    private func normalizedBootstrapHandoffGrants(
        _ grants: [OpenClawHelloOK.Auth.DeviceTokenGrant]
    ) -> [OpenClawHelloOK.Auth.DeviceTokenGrant] {
        // Pre-auth frames already have a byte ceiling; additionally bound the
        // number of secure-store mutations a single Hello may request.
        guard grants.count <= Self.maximumBootstrapHandoffTokens else {
            return []
        }

        var order: [String] = []
        var latestByRole: [
            String: OpenClawHelloOK.Auth.DeviceTokenGrant
        ] = [:]

        for grant in grants {
            let role = grant.role.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !role.isEmpty, !grant.token.isEmpty else { continue }

            if latestByRole[role] == nil {
                order.append(role)
            }
            // Duplicate roles are an in-band rotation: the last valid grant in
            // this authoritative Hello wins before the single CAS write.
            latestByRole[role] = .init(
                token: grant.token,
                role: role,
                scopes: grant.scopes
            )
        }

        return order.compactMap { latestByRole[$0] }
    }

    private static func bootstrapPrimaryStorageRole(
        requestedRole: String
    ) -> String {
        "bootstrap-primary-v1|\(requestedRole)"
    }
}
