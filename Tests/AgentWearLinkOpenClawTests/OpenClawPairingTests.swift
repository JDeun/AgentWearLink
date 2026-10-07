import Foundation
import XCTest
@testable import AgentWearLinkOpenClaw

final class OpenClawPairingTests: XCTestCase {
    func testParsesPairingRequiredDetails() throws {
        let data = Data(#"""
        {
          "type":"res",
          "id":"connect-1",
          "ok":false,
          "error":{
            "code":"NOT_PAIRED",
            "message":"pairing required",
            "retryable":true,
            "retryAfterMs":250,
            "details":{
              "code":"PAIRING_REQUIRED",
              "requestId":"req-123",
              "deviceId":"device-abc",
              "reason":"not-paired",
              "recommendedNextStep":"wait_then_retry",
              "waitForResolution":true,
              "pauseReconnect":false
            }
          }
        }
        """#.utf8)

        let response = try JSONDecoder().decode(
            OpenClawResponseEnvelope.self,
            from: data
        )
        let pairing = OpenClawPairingRequired(error: response.error!)

        XCTAssertEqual(pairing?.requestID, "req-123")
        XCTAssertEqual(pairing?.deviceID, "device-abc")
        XCTAssertEqual(pairing?.reason, "not-paired")
        XCTAssertEqual(pairing?.recommendedNextStep, "wait_then_retry")
        XCTAssertEqual(pairing?.waitForResolution, true)
        XCTAssertEqual(pairing?.pauseReconnect, false)
        XCTAssertEqual(pairing?.retryable, true)
        XCTAssertEqual(pairing?.retryAfterMilliseconds, 250)
    }

    func testParsesDeviceTokenRetryHintOnlyForAuthoritativeGuidance() throws {
        let data = Data(#"""
        {
          "type":"res",
          "id":"connect-1",
          "ok":false,
          "error":{
            "code":"AUTH_FAILED",
            "message":"shared token rejected",
            "retryable":false,
            "details":{
              "code":"TOKEN_MISMATCH",
              "reason":"shared-token-invalid",
              "canRetryWithDeviceToken":true,
              "recommendedNextStep":"retry_with_device_token"
            }
          }
        }
        """#.utf8)

        let response = try JSONDecoder().decode(
            OpenClawResponseEnvelope.self,
            from: data
        )
        let hint = OpenClawDeviceTokenRetryHint(error: response.error!)

        XCTAssertEqual(hint?.code, "TOKEN_MISMATCH")
        XCTAssertEqual(hint?.reason, "shared-token-invalid")
        XCTAssertEqual(hint?.recommendedNextStep, "retry_with_device_token")
    }

    func testDeviceTokenRetryHintRejectsExplicitDenial() throws {
        let data = Data(#"""
        {
          "type":"res",
          "id":"connect-1",
          "ok":false,
          "error":{
            "code":"AUTH_FAILED",
            "message":"denied",
            "details":{
              "canRetryWithDeviceToken":false,
              "recommendedNextStep":"retry_with_device_token"
            }
          }
        }
        """#.utf8)

        let response = try JSONDecoder().decode(
            OpenClawResponseEnvelope.self,
            from: data
        )
        XCTAssertNil(OpenClawDeviceTokenRetryHint(error: response.error!))
    }

}
