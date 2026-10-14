import XCTest

final class CompanionSettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "CompanionSettingsTests"

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testDefaultsAreListeningAndVoiceStyleOn() {
        let settings = CompanionSettingsStore(defaults: defaults).load()
        XCTAssertFalse(settings.setupCompleted)
        XCTAssertTrue(settings.listenEnabled)
        XCTAssertTrue(settings.voiceStyle)
        XCTAssertFalse(settings.telegramEnabled)
    }

    func testRoundTripAndReset() {
        let store = CompanionSettingsStore(defaults: defaults)
        var settings = CompanionSettings()
        settings.setupCompleted = true
        settings.gatewayURL = "wss://gateway.example.ts.net"
        settings.agentName = "Nova"
        settings.wakePhrases = ["Nova", "노바"]
        settings.listenEnabled = false
        settings.telegramEnabled = true
        settings.telegramChatID = "-100123"
        settings.voiceStyle = false
        settings.lastReplyAt = Date(timeIntervalSince1970: 1_000)
        settings.lastReplyLatency = 3.5
        store.save(settings)
        XCTAssertEqual(store.load(), settings)

        store.reset()
        XCTAssertEqual(store.load(), CompanionSettings())
    }

    func testSetupNeverCountsAsCompleteWithoutAnEndpoint() {
        defaults.set(true, forKey: CompanionSettingsStore.Key.setupCompleted)
        XCTAssertFalse(CompanionSettingsStore(defaults: defaults).load().setupCompleted)
    }

    func testStoresNoTokenLikeKeys() {
        XCTAssertFalse(CompanionSettingsStore.Key.all.contains { $0.lowercased().contains("token") })
    }

    func testEffectiveWakePhrasesFallBackToAgentName() {
        var settings = CompanionSettings()
        settings.agentName = "Nova"
        XCTAssertEqual(settings.effectiveWakePhrases.first, "Nova")
        settings.wakePhrases = ["  ", "Hey Nova"]
        XCTAssertEqual(settings.effectiveWakePhrases, ["Hey Nova"])
    }

    func testTelegramConfiguredNeedsToggleAndValidChatID() {
        var settings = CompanionSettings()
        settings.telegramChatID = "12345"
        XCTAssertFalse(settings.isTelegramDeliveryConfigured)
        settings.telegramEnabled = true
        XCTAssertTrue(settings.isTelegramDeliveryConfigured)
        settings.telegramChatID = "@channel"
        XCTAssertFalse(settings.isTelegramDeliveryConfigured)
    }
}
