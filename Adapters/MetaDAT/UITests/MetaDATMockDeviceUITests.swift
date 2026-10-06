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
        XCTAssertTrue(
            await client.waitForServer(timeout: 15),
            "App-hosted MockDeviceKit server did not become ready"
        )
    }

    override func tearDown() async throws {
        if let pairedDeviceID {
            XCTAssertTrue(await client.unpairDevice(deviceId: pairedDeviceID))
        }
        pairedDeviceID = nil
        client = nil
    }

    func testPairRayBanMetaAndDriveWearableReadyState() async throws {
        let deviceID = try XCTUnwrap(await client.pairDevice())
        pairedDeviceID = deviceID

        XCTAssertTrue(await client.powerOn(deviceId: deviceID))
        XCTAssertTrue(await client.unfold(deviceId: deviceID))
        XCTAssertTrue(await client.don(deviceId: deviceID))

        let state = await client.getDeviceState()
        XCTAssertNotNil(state, "Mock server must expose app-visible device state")
    }
}
