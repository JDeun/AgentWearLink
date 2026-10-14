import Foundation
import XCTest
@testable import AgentWearLinkOpenClaw

final class OpenClawSetupCodeTests: XCTestCase {
    private func encode(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testDecodesGatewaySetupCode() throws {
        let code = try encode([
            "url": "wss://gateway.example.ts.net:8443",
            "bootstrapToken": "synthetic-bootstrap",
            "expiresAtMs": 1_800_000_600_000,
        ])
        let setup = try OpenClawSetupCode(code, now: now)
        XCTAssertEqual(setup.url.absoluteString, "wss://gateway.example.ts.net:8443")
        XCTAssertEqual(setup.bootstrapToken, "synthetic-bootstrap")
        XCTAssertEqual(setup.expiresAt, Date(timeIntervalSince1970: 1_800_000_600))
    }

    func testDecodesOutputOfTheGatewayEncoder() throws {
        // encodePairingSetupCode() from OpenClaw 2026.9.6 with synthetic values.
        let code = "eyJ1cmwiOiJ3c3M6Ly9nYXRld2F5LmV4YW1wbGUudHMubmV0Ojg0NDMiLCJib290c3RyYXBUb2tlbiI6InN5bnRoZXRpYy1ib290c3RyYXAiLCJleHBpcmVzQXRNcyI6NDEwMjQ0NDgwMDAwMH0"
        let setup = try OpenClawSetupCode(code, now: now)
        XCTAssertEqual(setup.url.absoluteString, "wss://gateway.example.ts.net:8443")
        XCTAssertEqual(setup.bootstrapToken, "synthetic-bootstrap")
    }

    func testAcceptsPairingURLPrefixAndSurroundingWhitespace() throws {
        let code = try encode(["url": "wss://gateway.example", "bootstrapToken": "t"])
        let setup = try OpenClawSetupCode("  OC-PAIR://\(code)\n", now: now)
        XCTAssertEqual(setup.url.host, "gateway.example")
    }

    func testRejectsExpiredCode() throws {
        let code = try encode([
            "url": "wss://gateway.example", "bootstrapToken": "t", "expiresAtMs": 1_799_999_999_000,
        ])
        XCTAssertThrowsError(try OpenClawSetupCode(code, now: now)) {
            XCTAssertEqual($0 as? OpenClawSetupCodeError, .expired)
        }
    }

    func testRejectsMissingFieldsBadSchemeAndGarbage() throws {
        for object: [String: Any] in [
            ["url": "wss://gateway.example"],
            ["bootstrapToken": "t"],
            ["url": "https://gateway.example", "bootstrapToken": "t"],
            ["url": "wss://gateway.example", "bootstrapToken": "   "],
        ] {
            XCTAssertThrowsError(try OpenClawSetupCode(try encode(object), now: now))
        }
        XCTAssertThrowsError(try OpenClawSetupCode("not base64 !!", now: now))
        XCTAssertThrowsError(try OpenClawSetupCode("", now: now))
    }

    func testDescriptionNeverRevealsTheBootstrapToken() throws {
        let code = try encode(["url": "wss://gateway.example", "bootstrapToken": "secret-value"])
        let setup = try OpenClawSetupCode(code, now: now)
        XCTAssertFalse(String(describing: setup).contains("secret-value"))
        XCTAssertFalse(String(reflecting: setup).contains("secret-value"))
    }
}
