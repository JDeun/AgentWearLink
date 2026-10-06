import Foundation
import XCTest
@testable import AgentWearLinkOpenClaw

final class OpenClawProtocolTests: XCTestCase {
    func testConnectFrameUsesCurrentProtocolAndOperatorRole() throws {
        let params = OpenClawConnectParams(
            version: "0.1.0",
            auth: .init(token: "secret")
        )
        let frame = OpenClawRequestFrame(
            id: "connect-1",
            method: "connect",
            params: params
        )

        let data = try JSONEncoder().encode(frame)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let encodedParams = json["params"] as! [String: Any]

        XCTAssertEqual(json["type"] as? String, "req")
        XCTAssertEqual(json["method"] as? String, "connect")
        XCTAssertEqual(encodedParams["minProtocol"] as? Int, 4)
        XCTAssertEqual(encodedParams["maxProtocol"] as? Int, 4)
        XCTAssertEqual(encodedParams["role"] as? String, "operator")

        let client = try XCTUnwrap(encodedParams["client"] as? [String: Any])
        XCTAssertEqual(client["id"] as? String, "gateway-client")
        XCTAssertEqual(client["mode"] as? String, "backend")
        XCTAssertEqual(client["platform"] as? String, "ios")
        XCTAssertEqual(client["deviceFamily"] as? String, "iphone")
    }

    func testDecodesGatewayResponseEnvelope() throws {
        let data = Data(#"""
        {
          "type":"res",
          "id":"1",
          "ok":true,
          "payload":{"type":"hello-ok","protocol":4}
        }
        """#.utf8)

        let response = try JSONDecoder().decode(
            OpenClawResponseEnvelope.self,
            from: data
        )

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.id, "1")
    }

    func testDecodesGatewayEventEnvelope() throws {
        let data = Data(#"""
        {
          "type":"event",
          "event":"agent",
          "payload":{"text":"hello"},
          "seq":7
        }
        """#.utf8)

        let event = try JSONDecoder().decode(
            OpenClawEventEnvelope.self,
            from: data
        )

        XCTAssertEqual(event.event, "agent")
        XCTAssertEqual(event.seq, 7)
    }

    func testJSONValuePreservesIntegerPrecisionAcrossRoundTrip() throws {
        let fixtures: [(String, JSONValue)] = [
            ("9007199254740991", .integer(9_007_199_254_740_991)),
            ("9007199254740992", .integer(9_007_199_254_740_992)),
            ("9007199254740993", .integer(9_007_199_254_740_993)),
            ("9223372036854775807", .integer(Int64.max)),
            ("18446744073709551615", .unsignedInteger(UInt64.max)),
            ("1.25", .number(1.25))
        ]

        for (json, expected) in fixtures {
            let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
            XCTAssertEqual(decoded, expected)

            let encoded = try JSONEncoder().encode(decoded)
            let roundTripped = try JSONDecoder().decode(JSONValue.self, from: encoded)
            XCTAssertEqual(roundTripped, expected)
        }
    }

}
