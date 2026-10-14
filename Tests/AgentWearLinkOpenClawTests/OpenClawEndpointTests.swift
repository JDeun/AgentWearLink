import XCTest
@testable import AgentWearLinkOpenClaw

final class OpenClawEndpointTests: XCTestCase {
    func testTailnetServeBuildsSecureWebSocketURL() throws {
        let endpoint = try OpenClawEndpoint.tailnetServe(
            hostname: "mac-mini.example.ts.net"
        )

        XCTAssertEqual(
            endpoint.gatewayURL.absoluteString,
            "wss://mac-mini.example.ts.net"
        )
        XCTAssertEqual(endpoint.exposure, .tailnetServe)
    }

    func testTailnetServeAcceptsExplicitPort() throws {
        // A Mac whose port 443 already carries a Funnel (for example a chat webhook)
        // serves the Gateway on a separate tailnet-only HTTPS port.
        let endpoint = try OpenClawEndpoint.tailnetServe(
            hostname: "mac-mini.example.ts.net:8443"
        )

        XCTAssertEqual(
            endpoint.gatewayURL.absoluteString,
            "wss://mac-mini.example.ts.net:8443"
        )
        XCTAssertEqual(endpoint.gatewayURL.port, 8443)
        XCTAssertEqual(endpoint.exposure, .tailnetServe)
    }

    func testTailnetServePortSeparatesCredentialNamespaceButDefaultPortDoesNot() throws {
        let plain = try OpenClawEndpoint.tailnetServe(hostname: "mac-mini.example.ts.net")
        let explicitDefault = try OpenClawEndpoint.tailnetServe(hostname: "mac-mini.example.ts.net:443")
        let custom = try OpenClawEndpoint.tailnetServe(hostname: "mac-mini.example.ts.net:8443")

        XCTAssertEqual(plain.credentialNamespace, explicitDefault.credentialNamespace)
        XCTAssertNotEqual(plain.credentialNamespace, custom.credentialNamespace)
    }

    func testTailnetServeRejectsHostnameWithQueryFragmentUserInfoOrBadPort() {
        for input in [
            "mac-mini.example.ts.net?x=1",
            "mac-mini.example.ts.net#frag",
            "attacker@mac-mini.example.ts.net",
            "mac-mini.example.ts.net:0",
            "mac-mini.example.ts.net:70000",
            "mac-mini.example.ts.net:abc",
        ] {
            XCTAssertThrowsError(
                try OpenClawEndpoint.tailnetServe(hostname: input),
                input
            )
        }
    }

    func testTailnetServeRejectsPlainWebSocket() {
        XCTAssertThrowsError(
            try OpenClawEndpoint(
                gatewayURL: URL(string: "ws://mac-mini.example.ts.net")!,
                exposure: .tailnetServe
            )
        ) { error in
            XCTAssertEqual(
                error as? OpenClawEndpointError,
                .secureTransportRequired
            )
        }
    }

    func testPrivateReverseProxyRejectsPlainWebSocket() {
        XCTAssertThrowsError(
            try OpenClawEndpoint(
                gatewayURL: URL(string: "ws://gateway.example.com")!,
                exposure: .privateReverseProxy
            )
        ) { error in
            XCTAssertEqual(
                error as? OpenClawEndpointError,
                .secureTransportRequired
            )
        }
    }

    func testLoopbackAcceptsLocalhostIPv4AndIPv6() throws {
        for rawURL in [
            "ws://localhost:18789",
            "ws://127.0.0.1:18789",
            "ws://[::1]:18789",
        ] {
            _ = try OpenClawEndpoint(
                gatewayURL: URL(string: rawURL)!,
                exposure: .loopback
            )
        }
    }

    func testLoopbackRejectsPublicHost() {
        XCTAssertThrowsError(
            try OpenClawEndpoint(
                gatewayURL: URL(string: "ws://example.com:18789")!,
                exposure: .loopback
            )
        ) { error in
            XCTAssertEqual(
                error as? OpenClawEndpointError,
                .exposureHostMismatch
            )
        }
    }

    func testLoopbackRejectsHostnameThatOnlyStartsWith127() {
        XCTAssertThrowsError(
            try OpenClawEndpoint(
                gatewayURL: URL(string: "ws://127.attacker.example:18789")!,
                exposure: .loopback
            )
        ) { error in
            XCTAssertEqual(
                error as? OpenClawEndpointError,
                .exposureHostMismatch
            )
        }
    }

    func testDirectTailnetAcceptsCGNATAndTailscaleIPv6() throws {
        for rawURL in [
            "ws://100.64.0.10:18789",
            "ws://100.127.255.254:18789",
            "ws://[fd7a:115c:a1e0::1]:18789",
        ] {
            _ = try OpenClawEndpoint(
                gatewayURL: URL(string: rawURL)!,
                exposure: .tailnetDirect
            )
        }
    }

    func testDirectTailnetRejectsPublicPlainWebSocket() {
        XCTAssertThrowsError(
            try OpenClawEndpoint(
                gatewayURL: URL(string: "ws://203.0.113.10:18789")!,
                exposure: .tailnetDirect
            )
        ) { error in
            XCTAssertEqual(
                error as? OpenClawEndpointError,
                .exposureHostMismatch
            )
        }
    }

    func testWebSocketConstructionRequiresWebSocketScheme() throws {
        let endpoint = try OpenClawEndpoint(
            gatewayURL: URL(string: "https://gateway.example.com")!,
            exposure: .privateReverseProxy
        )

        XCTAssertThrowsError(
            try URLSessionOpenClawWebSocket(endpoint: endpoint)
        ) { error in
            XCTAssertEqual(
                error as? OpenClawEndpointError,
                .webSocketSchemeRequired
            )
        }
    }

    func testValidatedEndpointConstructsProductionWebSocket() throws {
        let endpoint = try OpenClawEndpoint(
            gatewayURL: URL(string: "wss://gateway.example.com")!,
            exposure: .privateReverseProxy
        )

        _ = try URLSessionOpenClawWebSocket(endpoint: endpoint)
    }

    func testCredentialNamespaceCanonicalizesEquivalentEndpointSpelling() throws {
        let first = try OpenClawEndpoint(
            gatewayURL: URL(string: "wss://Gateway.Example.com:443")!,
            exposure: .privateReverseProxy
        )
        let second = try OpenClawEndpoint(
            gatewayURL: URL(string: "https://gateway.example.com/")!,
            exposure: .privateReverseProxy
        )

        XCTAssertEqual(first.credentialNamespace, second.credentialNamespace)
    }

    func testCredentialNamespaceSeparatesDifferentGatewayEndpoints() throws {
        let first = try OpenClawEndpoint(
            gatewayURL: URL(string: "wss://gateway-a.example.com")!,
            exposure: .privateReverseProxy
        )
        let second = try OpenClawEndpoint(
            gatewayURL: URL(string: "wss://gateway-b.example.com")!,
            exposure: .privateReverseProxy
        )

        XCTAssertNotEqual(first.credentialNamespace, second.credentialNamespace)
    }

    func testExplicitCredentialNamespaceCanUnifyTrustedAliases() throws {
        let serve = try OpenClawGatewayCredentialNamespace(
            stableIdentifier: "personal-openclaw-gateway"
        )
        let direct = try OpenClawGatewayCredentialNamespace(
            stableIdentifier: "personal-openclaw-gateway"
        )

        XCTAssertEqual(serve, direct)
    }

}
