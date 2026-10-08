import XCTest
import MWDATMockDeviceTestClient

@MainActor
final class AgentWearLinkMetaDATUITests: XCTestCase {
    func testMockDeviceServerRendezvousAndPairLifecycle() async throws {
        let portFile = NSTemporaryDirectory() + "awl-mwdat-\(UUID().uuidString).port"
        defer { try? FileManager.default.removeItem(atPath: portFile) }

        let app = XCUIApplication()
        app.launchArguments = ["--awl-meta-ui-testing", "--awl-meta-photo-ui-testing"]
        app.launchEnvironment["MWDAT_TEST_SERVER_PORT_FILE"] = portFile
        app.launch()
        // The first UI test used to leave its test host running on success.
        // Unconditionally retire this exact host after pair/unpair checks;
        // the next UI test must own a fresh MockDeviceKit server instance.
        defer { app.terminate() }

        let hostState = app.staticTexts["awl-meta-host-state"]
        XCTAssertTrue(hostState.waitForExistence(timeout: 10))
        let ready = NSPredicate(format: "label == %@", "host-ready")
        let readyExpectation = XCTNSPredicateExpectation(predicate: ready, object: hostState)
        guard XCTWaiter.wait(for: [readyExpectation], timeout: 15) == .completed else {
            XCTFail("Meta DAT test host did not become ready; state=\(hostState.label)")
            return
        }

        let client = MockDeviceTestClient(portFilePath: portFile)
        guard await client.waitForServer(timeout: 15) else {
            XCTFail("MockDeviceKit server did not publish its rendezvous port")
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

        let configurePhoto = app.buttons["awl-meta-configure-photo-fixture"]
        XCTAssertTrue(configurePhoto.waitForExistence(timeout: 5))
        configurePhoto.tap()
        let photoReady = NSPredicate(format: "label == %@", "photo-fixture-ready")
        let photoExpectation = XCTNSPredicateExpectation(
            predicate: photoReady,
            object: hostState
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [photoExpectation], timeout: 10),
            .completed,
            "Both mock still-photo routes must accept the host-owned fixture"
        )

        let photoAction = app.buttons["awl-meta-capture-mock-photo"]
        XCTAssertTrue(photoAction.waitForExistence(timeout: 5))
        photoAction.tap()
        let photoState = app.staticTexts["awl-meta-photo-state"]
        XCTAssertTrue(photoState.waitForExistence(timeout: 5))
        let captured = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "photo-snapshot-verified"),
            object: photoState
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [captured], timeout: 30),
            .completed,
            "Vendor one-shot photo capture was not validated; state=\(photoState.label)"
        )

        // The opt-in experimental Photo API must be exercised through the
        // same production adapter, without replacing its publishable default.
        let standalone = app.buttons["awl-meta-capture-experimental-photo"]
        XCTAssertTrue(standalone.waitForExistence(timeout: 5))
        standalone.tap()
        let standaloneCaptured = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "label == %@", "experimental-photo-snapshot-verified"
            ),
            object: photoState
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [standaloneCaptured], timeout: 30),
            .completed,
            "Experimental Camera.photo did not deliver bounded JPEG: state=\\(photoState.label)"
        )

        // Drive the SDK's own cameraCapture failure injector through
        // the *production* standalone Photo bridge. The previous success
        // establishes the same fixture can produce valid image bytes.
        let injectStandaloneFailure = app.buttons["awl-meta-fail-standalone-photo"]
        XCTAssertTrue(injectStandaloneFailure.waitForExistence(timeout: 5))
        injectStandaloneFailure.tap()
        standalone.tap()
        let failedStandalone = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "label == %@", "experimental-photo-capture-failed"
            ),
            object: photoState
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [failedStandalone], timeout: 15),
            .completed,
            "Injected standalone capture failure did not fail closed"
        )

        // The same real production snapshot entrypoint must fail closed
        // without a shutter request when the mock denies camera permission.
        let denyCamera = app.buttons["awl-meta-deny-camera-permission"]
        XCTAssertTrue(denyCamera.waitForExistence(timeout: 5))
        denyCamera.tap()
        photoAction.tap()
        let denied = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "photo-capture-failed"),
            object: photoState
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [denied], timeout: 15),
            .completed,
            "Denied camera permission did not fail predictably: state=\(photoState.label)"
        )

        let unpaired = await client.unpairDevice(deviceId: deviceID)
        XCTAssertTrue(unpaired)
    }
    func testMockVoiceLaunchAcknowledgedWithoutMediaSession() async throws {
        let portFile = NSTemporaryDirectory() + "awl-mwdat-voice-\(UUID().uuidString).port"
        defer { try? FileManager.default.removeItem(atPath: portFile) }

        let app = XCUIApplication()
        app.launchArguments = ["--awl-meta-ui-testing", "--awl-meta-voice-ui-testing"]
        app.launchEnvironment["MWDAT_TEST_SERVER_PORT_FILE"] = portFile
        app.launch()
        // Include thrown XCTUnwrap/assertion paths in teardown, too.
        defer { app.terminate() }

        let hostState = app.staticTexts["awl-meta-host-state"]
        XCTAssertTrue(hostState.waitForExistence(timeout: 15))
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "host-ready"),
            object: hostState
        )
        guard XCTWaiter.wait(for: [ready], timeout: 15) == .completed else {
            XCTFail("Voice MockDeviceKit host bootstrap failed")
            return
        }

        let client = MockDeviceTestClient(portFilePath: portFile)
        guard await client.waitForServer(timeout: 15) else {
            XCTFail("Voice MockDeviceKit test server unavailable")
            return
        }
        let paired = await client.pairDevice()
        let deviceID = try XCTUnwrap(paired)
        let poweredOn = await client.powerOn(deviceId: deviceID)
        let unfolded = await client.unfold(deviceId: deviceID)
        let donned = await client.don(deviceId: deviceID)
        XCTAssertTrue(poweredOn)
        XCTAssertTrue(unfolded)
        XCTAssertTrue(donned)

        let voiceState = app.staticTexts["awl-meta-voice-state"]
        XCTAssertTrue(voiceState.waitForExistence(timeout: 5))
        let listening = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "voice-listening"),
            object: voiceState
        )
        guard XCTWaiter.wait(for: [listening], timeout: 20) == .completed else {
            XCTFail("Voice channel was not ready: \(voiceState.label)")
            return
        }

        // Pinned real MockDeviceKit client -> VoiceInvocationsStream ->
        // Meta response handle -> concrete DeviceAdapter.events(), without
        // establishing any camera/Speech DeviceSession.
        _ = await client.sendLaunchAppAction(deviceId: deviceID)
        let acknowledged = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "voice-acknowledged"),
            object: voiceState
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [acknowledged], timeout: 15),
            .completed,
            "Acknowledged voice launch never reached the production adapter"
        )

        let unpaired = await client.unpairDevice(deviceId: deviceID)
        XCTAssertTrue(unpaired)
    }


    func testMockVoiceWakeHandsOffToSpeechAndCoreAgent() async throws {
        let portFile = NSTemporaryDirectory() + "awl-mwdat-wake-\(UUID().uuidString).port"
        defer { try? FileManager.default.removeItem(atPath: portFile) }

        let app = XCUIApplication()
        app.launchArguments = ["--awl-meta-ui-testing", "--awl-meta-wake-ui-testing"]
        app.launchEnvironment["MWDAT_TEST_SERVER_PORT_FILE"] = portFile
        app.launch()
        defer { app.terminate() }

        let host = app.staticTexts["awl-meta-host-state"]
        XCTAssertTrue(host.waitForExistence(timeout: 15))
        let hostReady = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "host-ready"),
            object: host
        )
        XCTAssertEqual(XCTWaiter.wait(for: [hostReady], timeout: 20), .completed)

        let client = MockDeviceTestClient(portFilePath: portFile)
        let serverReady = await client.waitForServer(timeout: 15)
        XCTAssertTrue(serverReady)
        let paired = await client.pairDevice()
        let deviceID = try XCTUnwrap(paired)
        let powered = await client.powerOn(deviceId: deviceID)
        let unfolded = await client.unfold(deviceId: deviceID)
        let donned = await client.don(deviceId: deviceID)
        XCTAssertTrue(powered)
        XCTAssertTrue(unfolded)
        XCTAssertTrue(donned)

        let wake = app.staticTexts["awl-meta-wake-state"]
        XCTAssertTrue(wake.waitForExistence(timeout: 10))
        let listening = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "wake-listening"),
            object: wake
        )
        XCTAssertEqual(XCTWaiter.wait(for: [listening], timeout: 25), .completed)

        // The Meta response handle is acknowledged before this separate
        // foreground media/Speech startup; LaunchApp contains no user text.
        _ = await client.sendLaunchAppAction(deviceId: deviceID)
        let acknowledged = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "wake-acknowledged"),
            object: wake
        )
        XCTAssertEqual(XCTWaiter.wait(for: [acknowledged], timeout: 15), .completed)

        let media = app.staticTexts["awl-meta-wake-media-state"]
        let speechReady = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "wake-speech-ready"),
            object: media
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [speechReady], timeout: 30),
            .completed,
            "Foreground media activation did not produce Speech readiness: \(media.label)"
        )

        let inject = app.buttons["awl-meta-send-mock-transcript"]
        XCTAssertTrue(inject.waitForExistence(timeout: 5))
        inject.tap()
        let completed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "wake-agent-completed"),
            object: wake
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [completed], timeout: 20),
            .completed,
            "Final DAT Speech did not reach Core and terminal MockAgent output: \(wake.label)"
        )

        let unpaired = await client.unpairDevice(deviceId: deviceID)
        XCTAssertTrue(unpaired)
    }

}
