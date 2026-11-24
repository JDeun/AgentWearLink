import XCTest
import MWDATMockDeviceTestClient

/// Behavioral client for the app-hosted MockDeviceKit server.
///
/// This target is intended to run as an XCUITest/UI-test client while a DEBUG
/// iOS host starts MetaDATMockHostBootstrap with --awl-meta-ui-testing.
final class MetaDATMockDeviceUITests: XCTestCase {
    private var client: MockDeviceTestClient!
    private var pairedGlasses: MockDeviceTestGlasses?

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
        defer {
            pairedGlasses = nil
            client = nil
        }
        if let pairedGlasses {
            try await client.kit.unpairDevice(pairedGlasses)
            let remaining = try await client.kit.pairedDevices
            XCTAssertFalse(remaining.contains(pairedGlasses))
        }
    }

    func testPairRayBanMetaAndDriveWearableReadyState() async throws {
        let glasses = try await client.kit.pairGlasses(model: .rayBanMeta)
        pairedGlasses = glasses

        try await glasses.powerOn()
        try await glasses.unfold()
        try await glasses.don()

        let paired = try await client.kit.pairedDevices
        XCTAssertTrue(paired.contains(glasses), "Mock kit must expose paired glasses")
    }
}
