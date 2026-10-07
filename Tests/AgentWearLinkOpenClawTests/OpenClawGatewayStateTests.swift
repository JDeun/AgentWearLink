import Foundation
import XCTest
@testable import AgentWearLinkOpenClaw

final class OpenClawGatewayStateTests: XCTestCase {
    private func hello(
        maxPayload: Int = 1024,
        presenceVersion: Int = 1,
        healthVersion: Int = 1,
        uptimeMs: Int = 100
    ) throws -> OpenClawHelloOK {
        let data = Data("""
        {
          "type":"hello-ok",
          "protocol":4,
          "server":{"version":"2026.10.0","connId":"c1"},
          "features":{"methods":["health","agent"],"events":["agent"]},
          "snapshot":{
            "presence":[],
            "health":{},
            "stateVersion":{"presence":\(presenceVersion),"health":\(healthVersion)},
            "uptimeMs":\(uptimeMs)
          },
          "auth":{"role":"operator","scopes":["operator.read","operator.write"]},
          "policy":{
            "maxPayload":\(maxPayload),
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

    func testNegativeSequenceIsRejected() async throws {
        let state = OpenClawGatewayState()

        do {
            try await state.observeSequence(-1)
            XCTFail("Expected invalid sequence")
        } catch let error as AWLOpenClawError {
            XCTAssertEqual(error, .invalidSequence(-1))
        }
    }

    func testSequenceExhaustionDoesNotOverflow() async throws {
        let state = OpenClawGatewayState()
        try await state.observeSequence(Int.max)

        do {
            try await state.observeSequence(Int.max)
            XCTFail("Expected sequence exhaustion")
        } catch let error as AWLOpenClawError {
            XCTAssertEqual(error, .sequenceExhausted(last: Int.max))
        }
    }

    func testReconnectClearsOldSnapshotAndAcceptsFreshAuthoritativeSnapshot() async throws {
        let state = OpenClawGatewayState()
        try await state.acceptHello(
            hello(presenceVersion: 2, healthVersion: 3, uptimeMs: 100)
        )

        let firstSnapshot = await state.hello?.snapshot
        XCTAssertEqual(
            firstSnapshot?.stateVersion,
            OpenClawStateVersion(presence: 2, health: 3)
        )

        await state.beginReconnect(attempt: 1)
        let clearedHello = await state.hello
        XCTAssertNil(clearedHello)

        try await state.acceptHello(
            hello(presenceVersion: 8, healthVersion: 13, uptimeMs: 20)
        )
        let refreshedSnapshot = await state.hello?.snapshot
        let connectionState = await state.connectionState

        XCTAssertEqual(
            refreshedSnapshot?.stateVersion,
            OpenClawStateVersion(presence: 8, health: 13)
        )
        XCTAssertEqual(refreshedSnapshot?.uptimeMs, 20)
        XCTAssertEqual(connectionState, .ready)
    }

    func testInvalidSnapshotVersionIsRejected() async throws {
        let state = OpenClawGatewayState()

        do {
            try await state.acceptHello(
                hello(presenceVersion: -1, healthVersion: 0)
            )
            XCTFail("Expected invalid snapshot")
        } catch let error as AWLOpenClawError {
            XCTAssertEqual(error, .invalidSnapshot)
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
