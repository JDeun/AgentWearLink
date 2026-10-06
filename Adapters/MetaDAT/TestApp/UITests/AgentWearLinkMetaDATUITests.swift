import XCTest
import MWDATMockDeviceTestClient

final class AgentWearLinkMetaDATUITests: XCTestCase {
    private var client: MockDeviceTestClient!
    private var pairedDeviceID: String?
    private var portFile: String!

    override func setUp() async throws {
        continueAfterFailure = false
        portFile = NSTemporaryDirectory() + "awl-mwdat-\(UUID().uuidString).port"

        let app = XCUIApplication()
        app.launchArguments = ["--awl-meta-ui-testing"]
        app.launchEnvironment["MWDAT_TEST_SERVER_PORT_FILE"] = portFile
        app.launch()

        XCTAssertTrue(app.staticTexts["awl-meta-host-state"].waitForExistence(timeout: 10))

        client = MockDeviceTestClient(portFilePath: portFile)
        XCTAssertTrue(await client.waitForServer(timeout: 15))
    }

    override func tearDown() async throws {
        if let pairedDeviceID {
            XCTAssertTrue(await client.unpairDevice(deviceId: pairedDeviceID))
        }
        if let portFile {
            try? FileManager.default.removeItem(atPath: portFile)
        }
    }

    func testPairAndDriveRayBanMetaReadyState() async throws {
        let id = try XCTUnwrap(await client.pairDevice())
        pairedDeviceID = id
        XCTAssertTrue(await client.powerOn(deviceId: id))
        XCTAssertTrue(await client.unfold(deviceId: id))
        XCTAssertTrue(await client.don(deviceId: id))
        XCTAssertNotNil(await client.getDeviceState())
    }
}
