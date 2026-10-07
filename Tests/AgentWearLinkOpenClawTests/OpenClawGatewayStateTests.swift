import Foundation
import XCTest
@testable import AgentWearLinkOpenClaw

final class OpenClawGatewayStateTests: XCTestCase {
    private func hello(
        maxPayload: Int = 1024,
        maxBufferedBytes: Int = 2048,
        tickIntervalMs: Int = 15_000,
        attachmentMaxBytes: Int = 1000,
        attachmentMaxImageBytes: Int = 500
    ) throws -> OpenClawHelloOK {
        let data = Data("""
        {
          "type":"hello-ok",
          "protocol":4,
          "server":{"version":"2026.10.0","connId":"c1"},
          "features":{"methods":["health","agent"],"events":["agent"]},
          "auth":{"role":"operator","scopes":["operator.read","operator.write"]},
          "policy":{
            "maxPayload":\(maxPayload),
            "maxBufferedBytes":\(maxBufferedBytes),
            "tickIntervalMs":\(tickIntervalMs),
            "attachments":{"maxBytes":\(attachmentMaxBytes),"maxImageBytes":\(attachmentMaxImageBytes)}
          }
        }
        """.utf8)
        return try JSONDecoder().decode(OpenClawHelloOK.self, from: data)
    }


    func testHelloPolicyAcceptsMaximumSupportedTickInterval() throws {
        XCTAssertNoThrow(
            try OpenClawGatewayState.validateHello(
                hello(tickIntervalMs: 3_600_000)
            )
        )
    }

    func testHelloPolicyRejectsInvalidNumericBoundaries() throws {
        let invalidPolicies: [OpenClawHelloOK] = [
            try hello(maxPayload: 0),
            try hello(maxPayload: -1),
            try hello(maxBufferedBytes: 0),
            try hello(maxBufferedBytes: -1),
            try hello(tickIntervalMs: 0),
            try hello(tickIntervalMs: -1),
            try hello(tickIntervalMs: 3_600_001),
            try hello(tickIntervalMs: Int.max),
            try hello(attachmentMaxBytes: 0),
            try hello(attachmentMaxBytes: -1),
            try hello(attachmentMaxImageBytes: 0),
            try hello(attachmentMaxImageBytes: -1)
        ]

        for policy in invalidPolicies {
            XCTAssertThrowsError(
                try OpenClawGatewayState.validateHello(policy)
            ) { error in
                XCTAssertEqual(error as? AWLOpenClawError, .invalidPolicy)
            }
        }
    }

    func testTimingConversionAvoidsNanosecondMultiplicationOverflow() {
        XCTAssertEqual(
            OpenClawGatewayTiming.doubledMilliseconds(Int.max),
            Int.max
        )
        XCTAssertEqual(
            OpenClawGatewayTiming.doubledMilliseconds(3_600_000),
            7_200_000
        )
        XCTAssertEqual(
            OpenClawGatewayTiming.duration(milliseconds: 1_000),
            .seconds(1)
        )
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
