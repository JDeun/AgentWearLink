import XCTest
@testable import AgentWearLinkMetaDATIntegration

final class MetaDATCameraIgnitionTests: XCTestCase {
    func testNonReadyVendorStatesDoNotRemainStreaming() async {
        let ignition = MetaDATCameraIgnition()

        await ignition.observe(.starting)
        XCTAssertEqual(await ignition.state, .starting)

        await ignition.observe(.streaming)
        XCTAssertEqual(await ignition.state, .streaming)

        await ignition.observe(.waitingForDevice)
        XCTAssertEqual(await ignition.state, .starting)

        await ignition.observe(.streaming)
        XCTAssertEqual(await ignition.state, .streaming)

        await ignition.observe(.stopping)
        XCTAssertEqual(await ignition.state, .starting)
    }

    func testPausedKeepsEstablishedStreamingGeneration() async {
        let ignition = MetaDATCameraIgnition()

        await ignition.observe(.streaming)
        await ignition.observe(.paused)

        XCTAssertEqual(await ignition.state, .streaming)
    }

    func testStoppedRetiresGenerationAndReturnsToIdle() async {
        let ignition = MetaDATCameraIgnition()

        await ignition.observe(.starting)
        await ignition.observe(.streaming)
        await ignition.observe(.stopped)

        XCTAssertEqual(await ignition.state, .idle)
    }
}
