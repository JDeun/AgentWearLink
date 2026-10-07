import XCTest
@testable import AgentWearLinkMetaDATIntegration

final class MetaDATCameraIgnitionTests: XCTestCase {
    private func assertState(
        _ ignition: MetaDATCameraIgnition,
        _ expected: MetaDATCameraIgnition.State,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let actual = await ignition.state
        XCTAssertEqual(actual, expected, file: file, line: line)
    }

    func testNonReadyVendorStatesDoNotRemainStreaming() async {
        let ignition = MetaDATCameraIgnition()

        await ignition.observe(.starting)
        await assertState(ignition, .starting)

        await ignition.observe(.streaming)
        await assertState(ignition, .streaming)

        await ignition.observe(.waitingForDevice)
        await assertState(ignition, .starting)

        await ignition.observe(.streaming)
        await assertState(ignition, .streaming)

        await ignition.observe(.stopping)
        await assertState(ignition, .starting)
    }

    func testPausedKeepsEstablishedStreamingGeneration() async {
        let ignition = MetaDATCameraIgnition()

        await ignition.observe(.streaming)
        await ignition.observe(.paused)

        await assertState(ignition, .streaming)
    }

    func testStoppedRetiresGenerationAndReturnsToIdle() async {
        let ignition = MetaDATCameraIgnition()

        await ignition.observe(.starting)
        await ignition.observe(.streaming)
        await ignition.observe(.stopped)

        await assertState(ignition, .idle)
    }
}
