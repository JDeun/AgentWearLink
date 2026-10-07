import XCTest
import MWDATMockDeviceTestClient

/// Behavioral client for the app-hosted MockDeviceKit server.
///
/// This target is intended to run as an XCUITest/UI-test client while a DEBUG
/// iOS host starts MetaDATMockHostBootstrap with --awl-meta-ui-testing.
final class MetaDATMockDeviceUITests: XCTestCase {
    private var client: MockDeviceTestClient!
    private var pairedDeviceID: String?

    override func setUp() async throws {
        continueAfterFailure = false

        guard let portFile = ProcessInfo.processInfo.environment["MWDAT_TEST_SERVER_PORT_FILE"],
              !portFile.isEmpty else {
            throw XCTSkip("MWDAT_TEST_SERVER_PORT_FILE must be supplied by the UI-test runner")
        }

        client = MockDeviceTestClient(portFilePath: portFile)
        let serverReady = await client.waitForServer(timeout: 15)
        XCTAssertTrue(
            serverReady,
            "App-hosted MockDeviceKit server did not become ready"
        )
    }

    override func tearDown() async throws {
        if let pairedDeviceID {
            let unpaired = await client.unpairDevice(deviceId: pairedDeviceID)
            XCTAssertTrue(unpaired)
        }
        pairedDeviceID = nil
        client = nil
    }

    func testPairRayBanMetaAndDriveWearableReadyState() async throws {
        let paired = await client.pairDevice()
        let deviceID = try XCTUnwrap(paired)
        pairedDeviceID = deviceID

        let poweredOn = await client.powerOn(deviceId: deviceID)
        let unfolded = await client.unfold(deviceId: deviceID)
        let donned = await client.don(deviceId: deviceID)
        XCTAssertTrue(poweredOn)
        XCTAssertTrue(unfolded)
        XCTAssertTrue(donned)

        let state = await client.getDeviceState()
        XCTAssertNotNil(state, "Mock server must expose app-visible device state")
    }
}
