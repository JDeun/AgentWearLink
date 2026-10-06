import XCTest
import MWDATMockDeviceTestClient

final class AgentWearLinkMetaDATUITests: XCTestCase {
    private var client: MockDeviceTestClient!
    private var pairedDeviceID: String?
    private var portFile: String!

    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        portFile = NSTemporaryDirectory() + "awl-mwdat-\(UUID().uuidString).port"

        app = XCUIApplication()
        app.launchArguments = ["--awl-meta-ui-testing"]
        app.launchEnvironment["MWDAT_TEST_SERVER_PORT_FILE"] = portFile
        app.launch()

        XCTAssertTrue(app.staticTexts["awl-meta-host-state"].waitForExistence(timeout: 10))

        client = MockDeviceTestClient(portFilePath: portFile)
    }

    override func tearDown() async throws {
        if let pairedDeviceID {
            let unpaired = await client.unpairDevice(deviceId: pairedDeviceID)
            XCTAssertTrue(unpaired)
        }
        if let portFile {
            try? FileManager.default.removeItem(atPath: portFile)
        }
    }

    func testHostLaunches() {
        XCTAssertTrue(app.staticTexts["awl-meta-host-state"].exists)
    }

    func testMockDeviceServerRendezvous() async {
        let serverReady = await client.waitForServer(timeout: 15)
        XCTAssertTrue(serverReady)
    }

    func testPairAndDriveRayBanMetaReadyState() async throws {
        let serverReady = await client.waitForServer(timeout: 15)
        XCTAssertTrue(serverReady)

        let pairedID = await client.pairDevice()
        let id = try XCTUnwrap(pairedID)
        pairedDeviceID = id
        let poweredOn = await client.powerOn(deviceId: id)
        XCTAssertTrue(poweredOn)
        let unfolded = await client.unfold(deviceId: id)
        XCTAssertTrue(unfolded)
        let donned = await client.don(deviceId: id)
        XCTAssertTrue(donned)
        let state = await client.getDeviceState()
        XCTAssertNotNil(state)
    }
}
