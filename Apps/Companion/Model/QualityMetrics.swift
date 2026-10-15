import Foundation

/// What the wake gate did with one final transcript.
public enum TranscriptVerdict: Equatable, Sendable {
    case forwarded
    /// The name alone: the next utterance goes through.
    case armedByName
    /// Heard speech without the name (not addressed to the agent).
    case ignoredWithoutName
    /// Dropped by the echo guard (the app's own reply in the glasses mic).
    case echoDropped
    /// "그만": the reply was stopped.
    case stop
    /// Nothing but whitespace/punctuation.
    case empty
}

public enum StopSource: String, Sendable {
    case voice
    case tap
}

/// Counts only, never text. Compared later against the glasses' own assistant.
public struct QualityCounters: Equatable, Sendable {
    public var forwards = 0
    public var armedByName = 0
    public var armedByTap = 0
    public var ignoredFinals = 0
    public var echoDrops = 0
    public var voiceStops = 0
    public var tapStops = 0
    /// False-trigger proxy: forwards whose turn ended without reply text.
    public var noReplyForwards = 0
    public var deafRestarts = 0
    /// Requests that went out with a glasses photo.
    public var photoTurns = 0
    /// Visual requests that went out without one (camera failed, heat, …).
    public var photoFailures = 0
    /// Minutes worn while listening was wanted.
    public var minutesWorn = 0
    /// Of those, minutes listening was actually up.
    public var minutesListening = 0

    public init() {}

    public var armed: Int { armedByName + armedByTap }
    public var stops: Int { voiceStops + tapStops }
    /// Listening minutes over worn minutes; nil before the first worn minute.
    public var availability: Double? {
        minutesWorn > 0 ? Double(minutesListening) / Double(minutesWorn) : nil
    }
}

/// Per-turn latency stages, measured from the final transcript (the gate
/// decision) to the forward, to the first reply text, to audio starting.
public struct TurnStages: Equatable, Sendable {
    public enum Voice: String, Sendable {
        case system
        case gateway
    }

    public var finalToForward: TimeInterval?
    public var forwardToFirstText: TimeInterval?
    public var firstTextToFirstAudio: TimeInterval?
    public var voice: Voice?

    public init(
        finalToForward: TimeInterval? = nil, forwardToFirstText: TimeInterval? = nil,
        firstTextToFirstAudio: TimeInterval? = nil, voice: Voice? = nil
    ) {
        self.finalToForward = finalToForward
        self.forwardToFirstText = forwardToFirstText
        self.firstTextToFirstAudio = firstTextToFirstAudio
        self.voice = voice
    }

    /// Numbers only, for the activity log.
    public var logLine: String {
        "turn latency: final→forward \(Self.format(finalToForward)), "
            + "forward→first text \(Self.format(forwardToFirstText)), "
            + "first text→first audio \(Self.format(firstTextToFirstAudio)) (\(voice?.rawValue ?? "no audio"))"
    }

    /// "40 ms" under a second, "2.1 s" above, "—" when not measured.
    public static func format(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "—" }
        if seconds < 1 { return "\(Int((seconds * 1000).rounded())) ms" }
        return String(format: "%.1f s", seconds)
    }
}

/// Follows one turn at a time. A turn is reported once: when its audio
/// starts, or when it is flushed (ended without audio, stopped, or replaced
/// by the next request).
public struct TurnStageTracker: Sendable {
    private var finalAt: Date?
    private var forwardAt: Date?
    private var textAt: Date?

    public init() {}

    /// A request was forwarded. Returns the previous turn if it was never
    /// reported.
    public mutating func forwarded(finalAt: Date, at date: Date) -> TurnStages? {
        let previous = flush()
        self.finalAt = finalAt
        forwardAt = date
        textAt = nil
        return previous
    }

    /// Reply text arrived; only the first one of a turn counts.
    public mutating func replyText(at date: Date) {
        guard forwardAt != nil, textAt == nil else { return }
        textAt = date
    }

    /// Forwarded, and still no reply text.
    public var awaitingText: Bool { forwardAt != nil && textAt == nil }

    /// Reply audio started playing. Reports the turn once.
    public mutating func audioStarted(voice: TurnStages.Voice, at date: Date) -> TurnStages? {
        guard let textAt else { return nil }
        var stages = current
        stages.firstTextToFirstAudio = max(0, date.timeIntervalSince(textAt))
        stages.voice = voice
        reset()
        return stages
    }

    /// The turn ended without audio (silenced, failed, stopped): reports
    /// what was measured, once.
    public mutating func flush() -> TurnStages? {
        guard forwardAt != nil else { return nil }
        let stages = current
        reset()
        return stages
    }

    private var current: TurnStages {
        var stages = TurnStages()
        if let finalAt, let forwardAt { stages.finalToForward = max(0, forwardAt.timeIntervalSince(finalAt)) }
        if let forwardAt, let textAt { stages.forwardToFirstText = max(0, textAt.timeIntervalSince(forwardAt)) }
        return stages
    }

    private mutating func reset() {
        finalAt = nil
        forwardAt = nil
        textAt = nil
    }
}

/// Counters since launch and for today (rolls over at local midnight),
/// plus today's turn latencies for medians.
public struct QualityMetrics: Sendable {
    public private(set) var sinceLaunch = QualityCounters()
    public private(set) var today = QualityCounters()
    public private(set) var todayTurns: [TurnStages] = []
    public private(set) var lastTurn: TurnStages?
    /// Today's capture latencies (camera attach → JPEG ready), seconds.
    public private(set) var todayPhotoCaptures: [TimeInterval] = []
    public private(set) var lastPhotoCapture: TimeInterval?
    private var day: DateComponents
    private let calendar: Calendar
    static let maximumTurns = 500

    public init(now: Date = Date(), calendar: Calendar = .current) {
        self.calendar = calendar
        day = calendar.dateComponents([.year, .month, .day], from: now)
    }

    public mutating func record(_ verdict: TranscriptVerdict, at date: Date = Date()) {
        update(at: date) { counters in
            switch verdict {
            case .forwarded: counters.forwards += 1
            case .armedByName: counters.armedByName += 1
            case .ignoredWithoutName: counters.ignoredFinals += 1
            case .echoDropped: counters.echoDrops += 1
            case .stop: break // counted by `stopped`, with its source
            case .empty: break
            }
        }
    }

    public mutating func armedByTap(at date: Date = Date()) {
        update(at: date) { $0.armedByTap += 1 }
    }

    public mutating func stopped(_ source: StopSource, at date: Date = Date()) {
        update(at: date) { counters in
            switch source {
            case .voice: counters.voiceStops += 1
            case .tap: counters.tapStops += 1
            }
        }
    }

    public mutating func noReply(at date: Date = Date()) {
        update(at: date) { $0.noReplyForwards += 1 }
    }

    public mutating func deafRestart(at date: Date = Date()) {
        update(at: date) { $0.deafRestarts += 1 }
    }

    /// One sample per minute: listening counts only while worn and wanted.
    public mutating func minute(worn: Bool, listening: Bool, at date: Date = Date()) {
        guard worn else {
            roll(at: date)
            return
        }
        update(at: date) { counters in
            counters.minutesWorn += 1
            if listening { counters.minutesListening += 1 }
        }
    }

    public mutating func turn(_ stages: TurnStages, at date: Date = Date()) {
        roll(at: date)
        lastTurn = stages
        todayTurns.append(stages)
        if todayTurns.count > Self.maximumTurns { todayTurns.removeFirst(todayTurns.count - Self.maximumTurns) }
    }

    /// A request went out with a photo.
    public mutating func photoTurn(at date: Date = Date()) {
        update(at: date) { $0.photoTurns += 1 }
    }

    /// A photo for a turn took `seconds` (camera attach → JPEG ready).
    public mutating func photoCaptured(seconds: TimeInterval, at date: Date = Date()) {
        roll(at: date)
        lastPhotoCapture = seconds
        todayPhotoCaptures.append(seconds)
        if todayPhotoCaptures.count > Self.maximumTurns {
            todayPhotoCaptures.removeFirst(todayPhotoCaptures.count - Self.maximumTurns)
        }
    }

    public mutating func photoFailed(at date: Date = Date()) {
        update(at: date) { $0.photoFailures += 1 }
    }

    public var medianPhotoCaptureToday: TimeInterval? {
        Self.median(todayPhotoCaptures)
    }

    /// Median of one stage over today's turns that measured it.
    public func medianToday(_ stage: KeyPath<TurnStages, TimeInterval?>) -> TimeInterval? {
        Self.median(todayTurns.compactMap { $0[keyPath: stage] })
    }

    public static func median(_ values: [TimeInterval]) -> TimeInterval? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    private mutating func update(at date: Date, _ change: (inout QualityCounters) -> Void) {
        roll(at: date)
        change(&sinceLaunch)
        change(&today)
    }

    private mutating func roll(at date: Date) {
        let current = calendar.dateComponents([.year, .month, .day], from: date)
        guard current != day else { return }
        day = current
        today = QualityCounters()
        todayTurns = []
        todayPhotoCaptures = []
    }
}

/// Time from losing listening to listening again. The clock runs only while
/// listening is wanted (worn, listening on, no call), so a doff or a call
/// measures how long it took to come back once it could.
public struct RecoveryTracker: Equatable, Sendable {
    public struct Recovery: Equatable, Sendable {
        public let reason: String
        public let seconds: TimeInterval

        public var logLine: String { "recovered in \(Int(seconds.rounded())) s after \(reason)" }
    }

    public private(set) var reason: String?
    private var accumulated: TimeInterval = 0
    private var downSince: Date?

    public init() {}

    public var isDown: Bool { reason != nil }

    /// Listening was lost for `reason`. The first reason of an outage wins.
    public mutating func lost(_ reason: String, shouldListen: Bool, at date: Date) {
        guard self.reason == nil else { return }
        self.reason = reason
        accumulated = 0
        downSince = shouldListen ? date : nil
    }

    /// Call on every change of the inputs. Returns the recovery once
    /// listening is up again.
    public mutating func update(shouldListen: Bool, listening: Bool, at date: Date) -> Recovery? {
        guard let reason else { return nil }
        if listening {
            let total = accumulated + (downSince.map { max(0, date.timeIntervalSince($0)) } ?? 0)
            self = RecoveryTracker()
            return Recovery(reason: reason, seconds: total)
        }
        if shouldListen, downSince == nil {
            downSince = date
        } else if !shouldListen, let since = downSince {
            accumulated += max(0, date.timeIntervalSince(since))
            downSince = nil
        }
        return nil
    }
}
