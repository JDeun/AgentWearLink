import Foundation
import XCTest
@testable import AgentWearLinkOpenClaw

final class OpenClawGatewayStateTests: XCTestCase {
    private func hello(maxPayload: Int = 1024) throws -> OpenClawHelloOK {
        let data = Data("""
        {
          "type":"hello-ok",
          "protocol":4,
          "server":{"version":"2026.10.0","connId":"c1"},
          "features":{"methods":["health","agent"],"events":["agent"]},
          "auth":{"role":"operator","scopes":["operator.read","operator.write"]},
          "policy":{
            "maxPayload":(maxPayload),
            "maxBufferedBytes":2048,
            "tickIntervalMs":15000,
            "attachments":{"maxBytes":1000,"maxImageBytes":500}
          }
        }
        """.utf8)
        return try JSONDecoder().decode(OpenClawHelloOK.self, from: data)
    }

    func testHelloMakesConnectionReady() async throws {
        let state = OpenClawGatewayState()
        await state.beginConnect()
        await state.beginAuthentication()
        try await state.acceptHello(hello())

        let connectionState = await state.connectionState
        let maxPayload = await state.hello?.policy.maxPayload
        XCTAssertEqual(connectionState, .ready)
        XCTAssertEqual(maxPayload, 1024)
    }

    func testNegotiatedPayloadLimitIsEnforced() async throws {
        let state = OpenClawGatewayState()
        try await state.acceptHello(hello(maxPayload: 8))

        try await state.validateOutboundFrameSize(8)

        do {
            try await state.validateOutboundFrameSize(9)
            XCTFail("Expected payload limit failure")
        } catch let error as AWLOpenClawError {
            XCTAssertEqual(error, .payloadTooLarge(actual: 9, maximum: 8))
        }
    }

    func testSequenceMustIncreaseOnOneSocket() async throws {
        let state = OpenClawGatewayState()
        try await state.observeSequence(1)
        try await state.observeSequence(2)

        do {
            try await state.observeSequence(2)
            XCTFail("Expected sequence failure")
        } catch let error as AWLOpenClawError {
            XCTAssertEqual(error, .sequenceGap(expected: 3, actual: 2))
        }
    }

    func testForwardSequenceGapIsRejected() async throws {
        let state = OpenClawGatewayState()
        try await state.observeSequence(10)

        do {
            try await state.observeSequence(12)
            XCTFail("Expected sequence gap")
        } catch let error as AWLOpenClawError {
            XCTAssertEqual(error, .sequenceGap(expected: 11, actual: 12))
        }
    }

    func testReconnectClearsNegotiatedPolicy() async throws {
        let state = OpenClawGatewayState()
        try await state.acceptHello(hello())
        await state.beginReconnect(attempt: 1)

        let hello = await state.hello
        let connectionState = await state.connectionState
        XCTAssertNil(hello)
        XCTAssertEqual(connectionState, .reconnecting(attempt: 1))
    }
}
