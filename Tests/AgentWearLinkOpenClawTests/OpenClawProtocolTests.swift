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
}
