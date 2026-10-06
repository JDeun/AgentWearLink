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

    func testDirectTailnetMayUseRawGatewayWebSocket() throws {
        let endpoint = try OpenClawEndpoint(
            gatewayURL: URL(string: "ws://100.64.0.10:18789")!,
            exposure: .tailnetDirect
        )

        XCTAssertEqual(endpoint.exposure, .tailnetDirect)
    }
}
