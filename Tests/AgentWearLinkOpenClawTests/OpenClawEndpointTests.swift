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
}
