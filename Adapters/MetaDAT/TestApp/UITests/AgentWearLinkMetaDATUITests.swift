import XCTest
import MWDATMockDeviceTestClient

@MainActor
final class AgentWearLinkMetaDATUITests: XCTestCase {
    func testMockDeviceServerRendezvousAndPairLifecycle() async throws {
        let portFile = NSTemporaryDirectory() + "awl-mwdat-\(UUID().uuidString).port"
        defer { try? FileManager.default.removeItem(atPath: portFile) }

        let app = XCUIApplication()
        app.launchArguments = ["--awl-meta-ui-testing"]
        app.launchEnvironment["MWDAT_TEST_SERVER_PORT_FILE"] = portFile
        app.launch()

        let hostState = app.staticTexts["awl-meta-host-state"]
        XCTAssertTrue(hostState.waitForExistence(timeout: 10))
        let ready = NSPredicate(format: "label == %@", "host-ready")
        let readyExpectation = XCTNSPredicateExpectation(predicate: ready, object: hostState)
        guard XCTWaiter.wait(for: [readyExpectation], timeout: 15) == .completed else {
            XCTFail("Meta DAT test host did not become ready; state=\(hostState.label)")
            app.terminate()
            return
        }

        let client = MockDeviceTestClient(portFilePath: portFile)
        guard await client.waitForServer(timeout: 15) else {
            XCTFail("MockDeviceKit server did not publish its rendezvous port")
            app.terminate()
            return
        }

        let paired = await client.pairDevice()
        let deviceID = try XCTUnwrap(paired)

        let poweredOn = await client.powerOn(deviceId: deviceID)
        XCTAssertTrue(poweredOn)
        let unfolded = await client.unfold(deviceId: deviceID)
        XCTAssertTrue(unfolded)
        let donned = await client.don(deviceId: deviceID)
        XCTAssertTrue(donned)

        let deviceState = await client.getDeviceState()
        XCTAssertNotNil(deviceState, "Mock server must expose the paired device state")

        let unpaired = await client.unpairDevice(deviceId: deviceID)
        XCTAssertTrue(unpaired)
    }
}
