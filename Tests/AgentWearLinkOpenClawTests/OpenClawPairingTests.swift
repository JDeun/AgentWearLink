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
    }
}
