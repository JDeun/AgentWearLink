import XCTest
import MWDATMockDeviceTestClient

@MainActor
final class AgentWearLinkMetaDATSessionLifecycleUITests: XCTestCase {
    func testUnregisteredSDKAndAWLRejectSessionCreation() async throws {
        try await verifyLifecycle(
            launchArgument: "--awl-meta-unregistered-lifecycle-ui-testing",
            pairGlasses: false,
            expected: "lifecycle-unregistered-verified"
        )
    }

    func testRegisteredSessionPauseResumeAndInvalidStateNoOps() async throws {
        try await verifyLifecycle(
            launchArgument: "--awl-meta-session-lifecycle-ui-testing",
            pairGlasses: true,
            expected: "lifecycle-pause-resume-verified"
        )
    }

    private func verifyLifecycle(
        launchArgument: String,
        pairGlasses: Bool,
        expected: String
    ) async throws {
        let portFile = NSTemporaryDirectory() + "awl-mwdat-lifecycle-\(UUID().uuidString).port"
        defer { try? FileManager.default.removeItem(atPath: portFile) }
        let app = XCUIApplication()
        app.launchArguments = ["--awl-meta-ui-testing", launchArgument]
        app.launchEnvironment["MWDAT_TEST_SERVER_PORT_FILE"] = portFile
        app.launch()
        defer { app.terminate() }

        let host = app.staticTexts["awl-meta-host-state"]
        XCTAssertTrue(host.waitForExistence(timeout: 15))
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "host-ready"), object: host
        )
        guard XCTWaiter.wait(for: [ready], timeout: 20) == .completed else {
            XCTFail("Lifecycle mock host did not become ready")
            return
        }
        let client = MockDeviceTestClient(portFilePath: portFile)
        guard await client.waitForServer(timeout: 15) else {
            XCTFail("Lifecycle mock server unavailable")
            return
        }
        var glasses: MockDeviceTestGlasses?
        if pairGlasses {
            let paired = try await client.kit.pairGlasses(model: .rayBanMeta)
            glasses = paired
            try await paired.powerOn()
            try await paired.unfold()
            try await paired.don()
        }

        let button = app.buttons["awl-meta-verify-session-lifecycle"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()
        let status = app.staticTexts["awl-meta-session-lifecycle-state"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        // Observe either explicit success or a redacted failure stage. Do not
        // wait the full timeout after the harness already reported failure.
        let terminal = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@ OR label BEGINSWITH %@", expected, "lifecycle-failed-"),
            object: status
        )
        let completed = XCTWaiter.wait(for: [terminal], timeout: 60)
        XCTAssertEqual(completed, .completed, "No lifecycle result: \(status.label)")
        XCTAssertEqual(status.label, expected)
        if let glasses {
            try await client.kit.unpairDevice(glasses)
        }
    }
}
