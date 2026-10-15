import XCTest

final class PowerLogTests: XCTestCase {
    private var quality: QualityCounters {
        var counters = QualityCounters()
        counters.forwards = 5
        counters.armedByName = 2
        counters.armedByTap = 1
        counters.ignoredFinals = 9
        counters.echoDrops = 4
        counters.voiceStops = 1
        counters.noReplyForwards = 1
        counters.minutesWorn = 60
        counters.minutesListening = 57
        counters.deafRestarts = 2
        return counters
    }

    private func sample(battery: Int? = 79) -> PowerSample {
        PowerSample(
            time: Date(timeIntervalSince1970: 1_791_986_000), glassesBattery: battery, glassesCharging: false,
            listening: true, speechPause: "listen", keepAliveRunning: true, outputs: "BluetoothA2DPOutput,Speaker",
            appActive: false, phoneLocked: true, speechStallRestarts: 12, turns: 3,
            quality: quality, lastLatencyFirstAudioMilliseconds: 2540
        )
    }

    func testLineHasEveryColumnAndNoStrayCommas() {
        let columns = sample().csvLine.split(separator: ",", omittingEmptySubsequences: false)
        XCTAssertEqual(columns.count, PowerSample.header.split(separator: ",").count)
        XCTAssertEqual(columns[6], "BluetoothA2DPOutput;Speaker")
        XCTAssertEqual(columns[1], "79")
        XCTAssertEqual(columns[9], "12")
    }

    func testQualityColumnsAreAppendedAfterTheOriginalOnes() {
        let header = PowerSample.header.split(separator: ",").map(String.init)
        XCTAssertEqual(Array(header.prefix(11)), [
            "time", "glasses_battery", "charging", "listening", "speech_pause", "keep_alive", "outputs",
            "app_active", "phone_locked", "stall_restarts", "turns",
        ])
        let columns = sample().csvLine.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        let named = Dictionary(uniqueKeysWithValues: zip(header, columns))
        XCTAssertEqual(named["turns"], "3")
        XCTAssertEqual(named["forwards"], "5")
        XCTAssertEqual(named["armed"], "3")
        XCTAssertEqual(named["ignored_finals"], "9")
        XCTAssertEqual(named["echo_drops"], "4")
        XCTAssertEqual(named["stops"], "1")
        XCTAssertEqual(named["no_reply"], "1")
        XCTAssertEqual(named["last_latency_first_audio_ms"], "2540")
        XCTAssertEqual(named["minutes_worn"], "60")
        XCTAssertEqual(named["minutes_listening"], "57")
        XCTAssertEqual(named["deaf_restarts"], "2")
    }

    func testFileWithAnOlderHeaderIsRotated() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("power-log.csv")
        try "time,glasses_battery,charging\n2026-10-14T10:00:00+09:00,80,0\n".write(to: url, atomically: true, encoding: .utf8)
        PowerLogFile(url: url).append(sample())
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix(PowerSample.header + "\n"))
        XCTAssertEqual(text.split(separator: "\n").count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("power-log.1.csv").path))
    }

    func testUnknownBatteryIsEmpty() {
        XCTAssertEqual(sample(battery: nil).csvLine.split(separator: ",", omittingEmptySubsequences: false)[1], "")
    }

    func testFileGetsHeaderOnceAndRotates() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var file = PowerLogFile(url: dir.appendingPathComponent("power-log.csv"))
        file.append(sample())
        file.append(sample())
        var text = try String(contentsOf: file.url, encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: "\n").filter { $0 == PowerSample.header }.count, 1)
        XCTAssertEqual(text.split(separator: "\n").count, 3)
        file.maximumBytes = 10
        file.append(sample())
        text = try String(contentsOf: file.url, encoding: .utf8)
        XCTAssertEqual(text.split(separator: "\n").count, 2, "rotated file starts with header + one line")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("power-log.1.csv").path))
    }
}
