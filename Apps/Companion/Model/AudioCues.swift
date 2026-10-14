import Foundation

/// Short tones that tell the wearer what the agent is doing, like the glasses'
/// own assistant does: the DAT SDK has no audio-cue API, so the app plays
/// them itself through its keep-alive engine (the audio session is never
/// touched for them).
public enum Earcon: String, CaseIterable, Sendable {
    /// The request was heard and sent (rising two notes).
    case accepted
    /// Speak now: name or double tap armed the gate, or a follow-up window
    /// opened after a reply.
    case listening
    /// Still waiting for the reply (one soft tick, repeated).
    case thinking
    /// The request failed (falling two notes).
    case failed

    public struct Tone: Equatable, Sendable {
        public let frequency: Double
        public let duration: TimeInterval
        public let gain: Float
    }

    public var tones: [Tone] {
        switch self {
        case .accepted:
            return [Tone(frequency: 660, duration: 0.07, gain: 0.18), Tone(frequency: 990, duration: 0.09, gain: 0.18)]
        case .listening:
            return [Tone(frequency: 880, duration: 0.08, gain: 0.16)]
        case .thinking:
            return [Tone(frequency: 520, duration: 0.05, gain: 0.08)]
        case .failed:
            return [Tone(frequency: 440, duration: 0.10, gain: 0.18), Tone(frequency: 300, duration: 0.14, gain: 0.18)]
        }
    }

    /// Mono samples at `sampleRate`, with a short fade at each tone's edges
    /// (no clicks) and a 30 ms gap between tones.
    public func samples(sampleRate: Double) -> [Float] {
        var out: [Float] = []
        let gap = Int(0.03 * sampleRate)
        for (index, tone) in tones.enumerated() {
            if index > 0 { out.append(contentsOf: repeatElement(0, count: gap)) }
            let count = Int(tone.duration * sampleRate)
            let fade = max(1, min(count / 2, Int(0.008 * sampleRate)))
            for n in 0..<count {
                let envelope = Float(min(1, Double(min(n, count - 1 - n)) / Double(fade)))
                let value = sin(2 * Double.pi * tone.frequency * Double(n) / sampleRate)
                out.append(Float(value) * tone.gain * envelope)
            }
        }
        return out
    }
}

/// When the thinking tick plays while a reply is pending.
public struct ThinkingCueSchedule: Equatable, Sendable {
    /// Silence after the accepted cue before the first tick (fast replies
    /// never tick).
    public var firstTick: TimeInterval = 1.6
    public var interval: TimeInterval = 2.0
    /// Stop ticking eventually; the failure path covers longer waits.
    public var maximumWait: TimeInterval = 90

    public init() {}

    /// Tick times, in seconds after the request was accepted.
    public var tickTimes: [TimeInterval] {
        stride(from: firstTick, through: maximumWait, by: interval).map { $0 }
    }
}

/// After a spoken reply, the next utterance within this window is forwarded
/// without the wake phrase ("이어 말하기").
public enum FollowUpWindow {
    public static let seconds: TimeInterval = 8
}
