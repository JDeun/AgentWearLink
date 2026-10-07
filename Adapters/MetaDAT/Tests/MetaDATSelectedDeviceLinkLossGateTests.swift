import XCTest
@testable import AgentWearLinkMetaDATIntegration

final class MetaDATSelectedDeviceLinkLossGateTests: XCTestCase {
    func testInitialDisconnectedObservationIsNotLoss() {
        var gate = MetaDATSelectedDeviceLinkLossGate()

        XCTAssertFalse(gate.observe(isConnected: false))
        XCTAssertFalse(gate.observe(isConnected: false))
    }

    func testEstablishedLinkLossSignalsExactlyOnce() {
        var gate = MetaDATSelectedDeviceLinkLossGate()

        XCTAssertFalse(gate.observe(isConnected: true))
        XCTAssertTrue(gate.observe(isConnected: false))
        XCTAssertFalse(gate.observe(isConnected: false))
    }

    func testInitiallyConnectedDeviceTreatsDisconnectAsLoss() {
        var gate = MetaDATSelectedDeviceLinkLossGate(initiallyConnected: true)

        XCTAssertTrue(gate.observe(isConnected: false))
        XCTAssertFalse(gate.observe(isConnected: false))
    }

    func testStartedSessionTreatsDisconnectAsLossWithoutPriorConnectedCallback() {
        var gate = MetaDATSelectedDeviceLinkLossGate()
        gate.markSessionStarted()

        XCTAssertTrue(gate.observe(isConnected: false))
        XCTAssertFalse(gate.observe(isConnected: false))
    }
}
