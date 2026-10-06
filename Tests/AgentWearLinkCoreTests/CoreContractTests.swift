import XCTest
@testable import AgentWearLinkCore

final class CoreContractTests: XCTestCase {
    func testCapabilitiesAreComposable() {
        let capabilities: CapabilitySet = [.textInput, .cameraSnapshot]

        XCTAssertTrue(capabilities.contains(.textInput))
        XCTAssertTrue(capabilities.contains(.cameraSnapshot))
        XCTAssertFalse(capabilities.contains(.rawAudioInput))
    }

    func testInteractionIDsAreStableValues() {
        let id = InteractionID()
        let event = InteractionEvent.text(id, "hello")

        XCTAssertEqual(event, .text(id, "hello"))
    }

    func testFailuresRemainTyped() {
        let id = InteractionID()
        let event = InteractionEvent.failed(id, .timeout)

        XCTAssertEqual(event, .failed(id, .timeout))
    }
}
