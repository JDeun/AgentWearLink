import XCTest

final class PowerLogTests: XCTestCase {
    private func sample(battery: Int? = 79) -> PowerSample {
        PowerSample(
            time: Date(timeIntervalSince1970: 1_791_986_000), glassesBattery: battery, glassesCharging: false,
            listening: true, speechPause: "listen", keepAliveRunning: true, outputs: "BluetoothA2DPOutput,Speaker",
            appActive: false, phoneLocked: true, speechStallRestarts: 12, turns: 3
        )
    }

    func testLineHasEveryColumnAndNoStrayCommas() {
        let columns = sample().csvLine.split(separator: ",", omittingEmptySubsequences: false)
        XCTAssertEqual(columns.count, PowerSample.header.split(separator: ",").count)
        XCTAssertEqual(columns[6], "BluetoothA2DPOutput;Speaker")
        XCTAssertEqual(columns[1], "79")
        XCTAssertEqual(columns[9], "12")
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
