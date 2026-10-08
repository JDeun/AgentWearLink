import XCTest
@testable import AgentWearLinkOpenClaw

final class OpenClawGatewayErrorCodePolicyTests: XCTestCase {
    func testKnownErrorCategoriesRemainActionable() {
        for code in ["AUTH_FAILED", "BUSY", "DEVICE_TOKEN_REJECTED", "PAIRING_REQUIRED", "RUN_NOT_FOUND"] {
            XCTAssertEqual(OpenClawGatewayErrorCodePolicy.safeCode(code), code)
        }
    }

    func testUnknownAndSensitiveCodesAreNeverReemitted() {
        for code in [
            "SECRET_SESSION_KEY=private",
            "api_key_abcd",
            "BUSY\nAuthorization: Bearer something",
            String(repeating: "X", count: 20_000),
            ""
        ] {
            XCTAssertEqual(OpenClawGatewayErrorCodePolicy.safeCode(code), "UNKNOWN")
        }
        XCTAssertEqual(OpenClawGatewayErrorCodePolicy.safeCode(nil), "UNKNOWN")
    }
}
