import AgentWearLinkOpenClaw
import XCTest

final class GatewayAddressTests: XCTestCase {
    func testTailnetServeHostname() throws {
        let endpoint = try GatewayAddress.endpoint(fromUserInput: " gateway.example.ts.net ")
        XCTAssertEqual(endpoint.exposure, .tailnetServe)
        XCTAssertEqual(endpoint.gatewayURL.absoluteString, "wss://gateway.example.ts.net")
    }

    func testHttpsBecomesWssAndDropsQuery() throws {
        let endpoint = try GatewayAddress.endpoint(fromUserInput: "https://gateway.example.ts.net/?token=secret#x")
        XCTAssertEqual(endpoint.gatewayURL.absoluteString, "wss://gateway.example.ts.net")
    }

    func testTailnetIPWithPortIsDirect() throws {
        let endpoint = try GatewayAddress.endpoint(fromUserInput: "100.101.102.103:18789")
        XCTAssertEqual(endpoint.exposure, .tailnetDirect)
        XCTAssertEqual(endpoint.gatewayURL.absoluteString, "ws://100.101.102.103:18789")
    }

    func testPublicPlaintextIsRefused() {
        XCTAssertThrowsError(try GatewayAddress.endpoint(fromUserInput: "ws://203.0.113.5:18789")) {
            XCTAssertEqual($0 as? GatewayAddressError, .insecure)
        }
    }

    func testPrivateTLSReverseProxyIsAccepted() throws {
        let endpoint = try GatewayAddress.endpoint(fromUserInput: "wss://gateway.example.com")
        XCTAssertEqual(endpoint.exposure, .privateReverseProxy)
    }

    func testEmptyAndCredentialURLsAreRefused() {
        XCTAssertThrowsError(try GatewayAddress.endpoint(fromUserInput: "  ")) {
            XCTAssertEqual($0 as? GatewayAddressError, .empty)
        }
        XCTAssertThrowsError(try GatewayAddress.endpoint(fromUserInput: "wss://user:pw@gateway.example.ts.net"))
    }

    func testSetupCodeURLMapsToEndpoint() throws {
        let payload = #"{"url":"wss://gateway.example.ts.net","bootstrapToken":"one-time"}"#
        let code = Data(payload.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let setup = try OpenClawSetupCode(code)
        XCTAssertEqual(try GatewayAddress.endpoint(for: setup.url).exposure, .tailnetServe)
    }

    func testDisplayHostIsTheFirstLabel() {
        XCTAssertEqual(GatewayAddress.displayHost("wss://gateway.example.ts.net"), "gateway")
        XCTAssertEqual(GatewayAddress.displayHost("nonsense"), "")
    }
}
