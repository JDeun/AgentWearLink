import MWDATMockDeviceTestClient
import XCTest

@MainActor
final class MetaDATMockHostUITests: XCTestCase {
    private let app = XCUIApplication()
    private var client: MockDeviceTestClient!
    private var pairedDeviceID: String?
    private var portFilePath = ""

    override func setUp() async throws {
        continueAfterFailure = false
        portFilePath = NSTemporaryDirectory() + "awl_mwdat_\(UUID().uuidString).txt"
        try? FileManager.default.removeItem(atPath: portFilePath)

        app.launchArguments = ["--awl-meta-ui-testing"]
        app.launchEnvironment["MWDAT_TEST_SERVER_PORT_FILE"] = portFilePath
        app.launch()

        client = MockDeviceTestClient(portFilePath: portFilePath)
        XCTAssertTrue(await client.waitForServer(timeout: 10))
    }

    override func tearDown() async throws {
        if let pairedDeviceID {
            _ = await client.unpairDevice(deviceId: pairedDeviceID)
        }
        app.terminate()
        try? FileManager.default.removeItem(atPath: portFilePath)
        client = nil
        pairedDeviceID = nil
    }

    func testPairAndUnpairIsVisibleThroughMockServer() async throws {
        let initial = await client.getDeviceState()
        XCTAssertEqual(initial?["pairedDeviceCount"] as? Int, 0)

        pairedDeviceID = await client.pairDevice()
        XCTAssertNotNil(pairedDeviceID)
        let paired = await client.getDeviceState()
        XCTAssertEqual(paired?["pairedDeviceCount"] as? Int, 1)

        _ = await client.unpairDevice(deviceId: pairedDeviceID!)
        pairedDeviceID = nil
        let final = await client.getDeviceState()
        XCTAssertEqual(final?["pairedDeviceCount"] as? Int, 0)
    }
}
