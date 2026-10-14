import Foundation

/// One line per minute of power-relevant state, so a battery A/B can tell
/// which part drains the glasses. Counts and states only: never transcripts.
public struct PowerSample: Equatable, Sendable {
    public var time: Date
    public var glassesBattery: Int?
    public var glassesCharging: Bool
    public var listening: Bool
    public var speechPause: String
    public var keepAliveRunning: Bool
    public var outputs: String
    public var appActive: Bool
    public var phoneLocked: Bool
    public var speechStallRestarts: Int
    public var turns: Int

    public init(
        time: Date, glassesBattery: Int?, glassesCharging: Bool, listening: Bool, speechPause: String,
        keepAliveRunning: Bool, outputs: String, appActive: Bool, phoneLocked: Bool,
        speechStallRestarts: Int, turns: Int
    ) {
        self.time = time
        self.glassesBattery = glassesBattery
        self.glassesCharging = glassesCharging
        self.listening = listening
        self.speechPause = speechPause
        self.keepAliveRunning = keepAliveRunning
        self.outputs = outputs
        self.appActive = appActive
        self.phoneLocked = phoneLocked
        self.speechStallRestarts = speechStallRestarts
        self.turns = turns
    }

    public static let header =
        "time,glasses_battery,charging,listening,speech_pause,keep_alive,outputs,app_active,phone_locked,stall_restarts,turns"

    public var csvLine: String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        iso.timeZone = TimeZone.current
        func b(_ value: Bool) -> String { value ? "1" : "0" }
        func field(_ text: String) -> String { text.replacingOccurrences(of: ",", with: ";") }
        return [
            iso.string(from: time), glassesBattery.map(String.init) ?? "", b(glassesCharging), b(listening),
            field(speechPause), b(keepAliveRunning), field(outputs), b(appActive), b(phoneLocked),
            String(speechStallRestarts), String(turns),
        ].joined(separator: ",")
    }
}

/// Appends samples to a CSV in the app container (fetch it with
/// `xcrun devicectl device copy from --domain-type appDataContainer`).
/// Rotates at `maximumBytes` so it can run for days.
public struct PowerLogFile {
    public let url: URL
    public var maximumBytes = 1_000_000

    public init(url: URL) { self.url = url }

    public func append(_ sample: PowerSample) {
        let manager = FileManager.default
        if let size = (try? manager.attributesOfItem(atPath: url.path)[.size]) as? Int, size > maximumBytes {
            let old = url.deletingPathExtension().appendingPathExtension("1.csv")
            try? manager.removeItem(at: old)
            try? manager.moveItem(at: url, to: old)
        }
        if !manager.fileExists(atPath: url.path) {
            try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? (PowerSample.header + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((sample.csvLine + "\n").utf8))
    }
}
