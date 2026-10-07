import Foundation
import XCTest
@testable import AgentWearLinkOpenClaw

final class OpenClawBootstrapHandoffTests: XCTestCase {
    private let challenge = OpenClawConnectChallenge(
        nonce: "bootstrap-handoff",
        ts: 1737264000000
    )

    func testTrustedBootstrapPersistsOperatorHandoffSeparatelyAndReusesIt() async throws {
        let identity = OpenClawDeviceIdentity.generate()
        let deviceID = try identity.deviceID
        let baseStore = InMemoryOpenClawDeviceCredentialStore()
        let endpoint = try OpenClawEndpoint.tailnetServe(
            hostname: "mac-mini.example.ts.net"
        )
        let assembler = makeAssembler(
            identity: identity,
            store: baseStore,
            endpoint: endpoint,
            trusted: true
        )

        let first = try await assembler.assemble(
            version: "0.1",
            scopes: ["operator.read", "operator.write"],
            credentials: .init(bootstrapToken: "bootstrap-secret"),
            challenge: challenge
        )
        XCTAssertTrue(first.usedBootstrapToken)

        try await assembler.persistHello(
            makeHello(
                primaryToken: "primary-bootstrap-token",
                handoffs: [
                    .init(
                        token: "operator-handoff-token",
                        role: "operator",
                        scopes: ["operator.read"]
                    )
                ]
            ),
            assembled: first
        )

        let scopedStore = GatewayScopedOpenClawDeviceCredentialStore(
            base: baseStore,
            namespace: endpoint.credentialNamespace
        )

        let operatorGrant = try await scopedStore.load(
            deviceID: deviceID,
            role: "operator"
        )
        XCTAssertEqual(operatorGrant?.token, "operator-handoff-token")
        XCTAssertEqual(operatorGrant?.scopes, ["operator.read"])

        let primaryGrant = try await scopedStore.load(
            deviceID: deviceID,
            role: "bootstrap-primary-v1|operator"
        )
        XCTAssertEqual(primaryGrant?.token, "primary-bootstrap-token")
        XCTAssertEqual(
            primaryGrant?.storageRole,
            "bootstrap-primary-v1|operator"
        )

        let reconnect = try await assembler.assemble(
            version: "0.1",
            scopes: ["operator.read", "operator.write", "operator.admin"],
            credentials: .init(bootstrapToken: "must-not-be-used"),
            challenge: .init(nonce: "reconnect", ts: 1737264000001)
        )

        XCTAssertTrue(reconnect.usedStoredCredential)
        XCTAssertFalse(reconnect.usedBootstrapToken)
        XCTAssertEqual(reconnect.effectiveToken, "operator-handoff-token")
        XCTAssertEqual(reconnect.params.auth?.deviceToken, "operator-handoff-token")
        XCTAssertEqual(reconnect.params.scopes, ["operator.read"])
    }

    func testUntrustedBootstrapDoesNotPersistHandoffToken() async throws {
        let identity = OpenClawDeviceIdentity.generate()
        let baseStore = InMemoryOpenClawDeviceCredentialStore()
        let endpoint = try OpenClawEndpoint.tailnetServe(
            hostname: "mac-mini.example.ts.net"
        )
        let assembler = makeAssembler(
            identity: identity,
            store: baseStore,
            endpoint: endpoint,
            trusted: false
        )

        let first = try await assembler.assemble(
            version: "0.1",
            scopes: ["operator.read"],
            credentials: .init(bootstrapToken: "bootstrap-secret"),
            challenge: challenge
        )

        try await assembler.persistHello(
            makeHello(
                primaryToken: "ordinary-primary-token",
                handoffs: [
                    .init(
                        token: "must-not-persist",
                        role: "operator",
                        scopes: ["operator.read"]
                    )
                ]
            ),
            assembled: first
        )

        let reconnect = try await assembler.assemble(
            version: "0.1",
            scopes: ["operator.read"],
            credentials: .init(bootstrapToken: "unused"),
            challenge: .init(nonce: "reconnect", ts: 1737264000001)
        )

        // Existing primary-token behavior remains intact, but the untrusted
        // handoff bearer never replaces it.
        XCTAssertEqual(reconnect.effectiveToken, "ordinary-primary-token")
        XCTAssertNotEqual(reconnect.effectiveToken, "must-not-persist")
    }

    func testMissingHandoffTokensPreservesPrimaryReconnectBehavior() async throws {
        let identity = OpenClawDeviceIdentity.generate()
        let baseStore = InMemoryOpenClawDeviceCredentialStore()
        let endpoint = try OpenClawEndpoint.tailnetServe(
            hostname: "mac-mini.example.ts.net"
        )
        let assembler = makeAssembler(
            identity: identity,
            store: baseStore,
            endpoint: endpoint,
            trusted: true
        )

        let first = try await assembler.assemble(
            version: "0.1",
            scopes: ["operator.read"],
            credentials: .init(bootstrapToken: "bootstrap"),
            challenge: challenge
        )
        try await assembler.persistHello(
            makeHello(primaryToken: "primary-only", handoffs: nil),
            assembled: first
        )

        let reconnect = try await assembler.assemble(
            version: "0.1",
            scopes: ["operator.read", "operator.write"],
            credentials: .init(bootstrapToken: "unused"),
            challenge: .init(nonce: "fresh", ts: 1737264000002)
        )

        XCTAssertEqual(reconnect.effectiveToken, "primary-only")
        XCTAssertTrue(reconnect.usedStoredCredential)
    }

    func testDuplicateHandoffRoleUsesLastGrantAsAuthoritativeRotation() async throws {
        let identity = OpenClawDeviceIdentity.generate()
        let baseStore = InMemoryOpenClawDeviceCredentialStore()
        let endpoint = try OpenClawEndpoint.tailnetServe(
            hostname: "mac-mini.example.ts.net"
        )
        let assembler = makeAssembler(
            identity: identity,
            store: baseStore,
            endpoint: endpoint,
            trusted: true
        )

        let first = try await assembler.assemble(
            version: "0.1",
            scopes: ["operator.read"],
            credentials: .init(bootstrapToken: "bootstrap"),
            challenge: challenge
        )
        try await assembler.persistHello(
            makeHello(
                primaryToken: "primary",
                handoffs: [
                    .init(
                        token: "old-handoff",
                        role: "operator",
                        scopes: ["operator.read"]
                    ),
                    .init(
                        token: "rotated-handoff",
                        role: "operator",
                        scopes: ["operator.read", "operator.write"]
                    )
                ]
            ),
            assembled: first
        )

        let reconnect = try await assembler.assemble(
            version: "0.1",
            scopes: ["operator.read"],
            credentials: .init(),
            challenge: .init(nonce: "after-rotation", ts: 1737264000003)
        )
        XCTAssertEqual(reconnect.effectiveToken, "rotated-handoff")
        XCTAssertEqual(
            reconnect.params.scopes,
            ["operator.read", "operator.write"]
        )
    }

    func testStaleBootstrapHelloCannotOverwriteWinningHandoff() async throws {
        let identity = OpenClawDeviceIdentity.generate()
        let baseStore = InMemoryOpenClawDeviceCredentialStore()
        let endpoint = try OpenClawEndpoint.tailnetServe(
            hostname: "mac-mini.example.ts.net"
        )
        let assembler = makeAssembler(
            identity: identity,
            store: baseStore,
            endpoint: endpoint,
            trusted: true
        )

        let firstSnapshot = try await assembler.assemble(
            version: "0.1",
            scopes: ["operator.read"],
            credentials: .init(bootstrapToken: "bootstrap-a"),
            challenge: challenge
        )
        let staleSnapshot = try await assembler.assemble(
            version: "0.1",
            scopes: ["operator.read"],
            credentials: .init(bootstrapToken: "bootstrap-b"),
            challenge: .init(nonce: "stale", ts: 1737264000001)
        )

        try await assembler.persistHello(
            makeHello(
                primaryToken: "primary-a",
                handoffs: [
                    .init(
                        token: "winner",
                        role: "operator",
                        scopes: ["operator.read"]
                    )
                ]
            ),
            assembled: firstSnapshot
        )
        try await assembler.persistHello(
            makeHello(
                primaryToken: "primary-b",
                handoffs: [
                    .init(
                        token: "stale-loser",
                        role: "operator",
                        scopes: ["operator.read", "operator.write"]
                    )
                ]
            ),
            assembled: staleSnapshot
        )

        let reconnect = try await assembler.assemble(
            version: "0.1",
            scopes: ["operator.read"],
            credentials: .init(),
            challenge: .init(nonce: "verify", ts: 1737264000004)
        )
        XCTAssertEqual(reconnect.effectiveToken, "winner")
        XCTAssertEqual(reconnect.params.scopes, ["operator.read"])
    }

    func testHandoffTokenDescriptionsRedactBearer() {
        let sentinel = "HANDOFF-SECRET-SENTINEL"
        let grant = OpenClawHelloOK.Auth.DeviceTokenGrant(
            token: sentinel,
            role: "operator",
            scopes: ["operator.read"]
        )
        let auth = OpenClawHelloOK.Auth(
            role: "bootstrap",
            scopes: [],
            deviceToken: sentinel,
            deviceTokens: [grant]
        )

        for rendered in [
            String(describing: grant),
            String(reflecting: grant),
            String(describing: auth),
            String(reflecting: auth)
        ] {
            XCTAssertFalse(rendered.contains(sentinel))
        }
    }

    private func makeAssembler(
        identity: OpenClawDeviceIdentity,
        store: InMemoryOpenClawDeviceCredentialStore,
        endpoint: OpenClawEndpoint,
        trusted: Bool
    ) -> OpenClawConnectAssembler {
        OpenClawConnectAssembler(
            identityManager: .init(
                store: InMemoryOpenClawDeviceIdentityStore(identity: identity)
            ),
            credentialStore: store,
            gatewayNamespace: endpoint.credentialNamespace,
            bootstrapHandoffPersistenceAllowed: trusted
        )
    }

    private func makeHello(
        primaryToken: String?,
        handoffs: [OpenClawHelloOK.Auth.DeviceTokenGrant]?
    ) -> OpenClawHelloOK {
        OpenClawHelloOK(
            type: "hello-ok",
            protocolVersion: 4,
            server: .init(version: "test", connId: "handoff"),
            features: .init(methods: [], events: []),
            auth: .init(
                role: "operator",
                scopes: ["operator.read", "operator.write"],
                deviceToken: primaryToken,
                deviceTokens: handoffs
            ),
            policy: .init(
                maxPayload: 1_024,
                maxBufferedBytes: 2_048,
                tickIntervalMs: 15_000,
                attachments: nil
            )
        )
    }
}
