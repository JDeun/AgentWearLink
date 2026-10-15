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
    /// Quality counters since launch (appended columns; see `header`).
    public var quality: QualityCounters
    /// Final transcript → first reply audio of the last turn that spoke, ms.
    public var lastLatencyFirstAudioMilliseconds: Int?
    /// Camera attach → JPEG ready of the last photo turn, ms.
    public var lastPhotoCaptureMilliseconds: Int?

    public init(
        time: Date, glassesBattery: Int?, glassesCharging: Bool, listening: Bool, speechPause: String,
        keepAliveRunning: Bool, outputs: String, appActive: Bool, phoneLocked: Bool,
        speechStallRestarts: Int, turns: Int,
        quality: QualityCounters = QualityCounters(), lastLatencyFirstAudioMilliseconds: Int? = nil,
        lastPhotoCaptureMilliseconds: Int? = nil
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
        self.quality = quality
        self.lastLatencyFirstAudioMilliseconds = lastLatencyFirstAudioMilliseconds
        self.lastPhotoCaptureMilliseconds = lastPhotoCaptureMilliseconds
    }

    /// New columns are only ever appended, so older parsers stay valid.
    public static let header =
        "time,glasses_battery,charging,listening,speech_pause,keep_alive,outputs,app_active,phone_locked,stall_restarts,turns"
        + ",forwards,armed,ignored_finals,echo_drops,stops,no_reply,last_latency_first_audio_ms"
        + ",minutes_worn,minutes_listening,deaf_restarts"
        + ",photo_turns,photo_failures,last_photo_capture_ms"

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
            String(quality.forwards), String(quality.armed), String(quality.ignoredFinals),
            String(quality.echoDrops), String(quality.stops), String(quality.noReplyForwards),
            lastLatencyFirstAudioMilliseconds.map(String.init) ?? "",
            String(quality.minutesWorn), String(quality.minutesListening), String(quality.deafRestarts),
            String(quality.photoTurns), String(quality.photoFailures),
            lastPhotoCaptureMilliseconds.map(String.init) ?? "",
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
        if let size = (try? manager.attributesOfItem(atPath: url.path)[.size]) as? Int,
           size > maximumBytes || !hasCurrentHeader() {
            // Too big, or written with an older header: start a new file.
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

    private func hasCurrentHeader() -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let prefix = (try? handle.read(upToCount: PowerSample.header.utf8.count + 1)) ?? Data()
        return prefix == Data((PowerSample.header + "\n").utf8)
    }
}
