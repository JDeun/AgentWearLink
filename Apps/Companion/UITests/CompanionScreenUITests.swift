import XCTest

/// Renders each companion screen through its DEBUG `-AWLPreview` fixture and
/// checks the parts a user acts on. Fixtures freeze the connection signals,
/// skip the Meta SDK and the Gateway, and never save settings, so these tests
/// need no glasses, no Tailnet and no credentials. They are UI evidence only,
/// not hardware evidence.
@MainActor
final class CompanionScreenUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: Home

    func testHomeAllConnected() {
        let app = launch("home-ok")
        expect(app, shows: "모두 연결됨")
        XCTAssertTrue(app.buttons["설정"].exists, "Home must offer the settings button")
    }

    func testHomeWaitingForGlassesIsNotAnError() {
        let app = launch("home-waiting")
        expect(app, shows: "안경을 기다리고 있어요")
    }

    // MARK: Setup

    func testSetupStepsRenderInOrder() {
        let steps: [(fixture: String, texts: [String])] = [
            ("setup-meta", ["처음 설정", "Meta AI 앱에서 허용하기"]),
            ("setup-mic", ["안경 마이크 허용하기"]),
            ("setup-tailscale", ["Tailscale 항상 켜기", "켜 두었어요"]),
        ]
        for step in steps {
            let app = launch(step.fixture)
            for text in step.texts { expect(app, shows: text, context: step.fixture) }
            app.terminate()
        }
    }

    func testPairingModesRenderAndSwitch() {
        let modes: [(fixture: String, prompt: String)] = [
            ("setup-pair-qr", "게이트웨이 컴퓨터의 QR을 찍어 주세요"),
            ("setup-pair-paste", "설정 코드를 붙여넣어 주세요"),
            ("setup-pair-manual", "주소를 직접 입력해 주세요"),
        ]
        for mode in modes {
            let app = launch(mode.fixture)
            expect(app, shows: mode.prompt, context: mode.fixture)
            app.terminate()
        }

        // The segmented control itself switches the form.
        let app = launch("setup-pair-paste")
        for segment in ["QR 찍기", "코드 붙여넣기", "직접 입력"] {
            XCTAssertTrue(app.buttons[segment].waitForExistence(timeout: 5), "missing segment \(segment)")
        }
        app.buttons["직접 입력"].tap()
        expect(app, shows: "주소를 직접 입력해 주세요")
        XCTAssertTrue(app.secureTextFields.firstMatch.waitForExistence(timeout: 5),
                      "manual pairing must take the one-time code in a secure field")
    }

    func testPairingStates() {
        let states: [(fixture: String, texts: [String])] = [
            ("setup-pair-waiting", ["승인을 기다리고 있어요", "이 기기 지문"]),
            ("setup-pair-expired", ["설정 코드가 만료됐어요", "새 QR 찍기"]),
            ("setup-pair-failed", ["게이트웨이 컴퓨터에 닿지 않아요", "Tailscale 열기", "처음부터 다시"]),
            ("setup-pair-success", ["연결됐어요", "다음"]),
        ]
        for state in states {
            let app = launch(state.fixture)
            for text in state.texts { expect(app, shows: text, context: state.fixture) }
            app.terminate()
        }
    }

    func testCallPractice() {
        let app = launch("setup-practice-matched")
        expect(app, shows: "호출됐어요")
        app.terminate()

        let unmatched = launch("setup-practice-unmatched")
        expect(unmatched, shows: "호출 이름으로 시작하지 않아 무시했어요")
    }

    // MARK: Settings

    func testSettingsConversationRows() {
        let app = launch("settings")
        XCTAssertTrue(app.navigationBars["설정"].waitForExistence(timeout: 15))
        for title in ["안경으로 듣기", "텔레그램에 기록", "짧게 말로 답하기", "이어 말하기", "알림음"] {
            let toggle = scrollTo(app.switches.matching(labelBeginsWith: title).firstMatch, in: app)
            XCTAssertTrue(toggle.exists, "missing toggle \(title)")
        }
        let voice = scrollTo(element(in: app, labelContains: "목소리"), in: app)
        XCTAssertTrue(voice.exists, "missing voice picker")

        // Turning a toggle off shows its consequence (fixtures never save it).
        let cues = scrollTo(app.switches.matching(labelBeginsWith: "알림음").firstMatch, in: app)
        XCTAssertEqual(cues.value as? String, "1")
        cues.switches.firstMatch.tap()
        expect(app, shows: "답이 올 때까지 아무 소리도 나지 않아요")
    }

    func testSettingsAdvancedWakeSourcePicker() {
        let app = launch("settings-expanded")
        XCTAssertTrue(app.navigationBars["설정"].waitForExistence(timeout: 15))
        let picker = scrollTo(element(in: app, labelContains: "호출 듣는 방식"), in: app)
        XCTAssertTrue(picker.exists, "missing wake source picker")
        XCTAssertTrue(picker.label.contains("안경 음성 인식"),
                      "the default wake source must be glasses speech; got \(picker.label)")
        expect(app, shows: "전체 기기 지문")
    }

    func testSettingsResetAsksForConfirmation() {
        let app = launch("settings-reset")
        expect(app, shows: "모두 지우기")
        expect(app, shows: "취소")
    }

    // MARK: Repair

    func testRepairScreens() {
        // Each broken hop shows its guidance and exactly the right action.
        let cases: [(fixture: String, action: String, guidance: String)] = [
            ("repair-network", "다시 확인", "이렇게 해 보세요"),
            ("repair-microphone", "안경 마이크 허용하기", "이렇게 해 보세요"),
            ("repair-pending", "승인했어요, 다시 확인", "이 화면은 승인되면 자동으로 넘어가요"),
            ("repair-revoked", "승인 다시 받기", "이렇게 해 보세요"),
            ("repair-registration", "Meta AI 앱 열기", "이렇게 해 보세요"),
        ]
        for repair in cases {
            let app = launch(repair.fixture)
            XCTAssertTrue(app.navigationBars["연결 문제 해결"].waitForExistence(timeout: 15),
                          "\(repair.fixture) did not open the repair screen")
            expect(app, shows: repair.action, context: repair.fixture)
            expect(app, shows: repair.guidance, context: repair.fixture)
            app.terminate()
        }
    }

    // MARK: Helpers

    private func launch(_ fixture: String) -> XCUIApplication {
        let app = XCUIApplication()
        // The fixtures and assertions are Korean regardless of the simulator.
        app.launchArguments = ["-AWLPreview", fixture, "-AppleLanguages", "(ko)", "-AppleLocale", "ko_KR"]
        app.launch()
        return app
    }

    private func element(in app: XCUIApplication, labelContains text: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", text))
            .firstMatch
    }

    private func expect(
        _ app: XCUIApplication, shows text: String, context: String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let found = scrollTo(element(in: app, labelContains: text), in: app)
        XCTAssertTrue(found.exists, "\(context): '\(text)' not on screen", file: file, line: line)
    }

    /// Waits for the element, scrolling down a little at a time when the
    /// screen is taller than the simulator (lists create rows lazily).
    @discardableResult
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) -> XCUIElement {
        if element.waitForExistence(timeout: 8) { return element }
        for _ in 0..<6 {
            app.swipeUp(velocity: .slow)
            if element.waitForExistence(timeout: 1) { return element }
        }
        return element
    }
}

private extension XCUIElementQuery {
    func matching(labelBeginsWith prefix: String) -> XCUIElementQuery {
        matching(NSPredicate(format: "label BEGINSWITH %@", prefix))
    }
}
