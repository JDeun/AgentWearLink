import AgentWearLinkAppleOutput
import AgentWearLinkCore
import AVFoundation
import Foundation

/// Owns the wake-phrase gate on one actor, shared by the DAT transcript
/// callback, the double-tap handler and the echo guard.
actor WakeGateBox {
    private var gate: AWLWakePhraseGate

    init(phrases: [String]) {
        gate = AWLWakePhraseGate(wakePhrases: phrases)
    }

    func replacePhrases(_ phrases: [String]) {
        gate = AWLWakePhraseGate(wakePhrases: phrases)
    }

    func evaluate(_ text: String) -> AWLWakePhraseGate.Decision { gate.evaluate(text) }
    func arm() { gate.arm() }
    func suppress(until date: Date) { gate.suppress(until: date) }
}

/// Mutes the wake gate while a reply is spoken (plus an echo tail) so the
/// glasses microphone does not turn the reply back into a request.
/// AVSpeechSynthesizer returns before speaking finishes, so the duration is
/// estimated from the text length.
struct EchoGuardSynthesizer: SpeechSynthesizing {
    let inner: any SpeechSynthesizing
    let gate: WakeGateBox
    static let secondsPerCharacter = 0.18
    static let echoTail: TimeInterval = 4

    func speak(_ text: String) async {
        let estimate = Double(text.count) * Self.secondsPerCharacter + Self.echoTail
        await gate.suppress(until: Date().addingTimeInterval(estimate))
        await inner.speak(text)
    }

    func stop() async { await inner.stop() }
}

/// A silent `.playback` + `.mixWithOthers` loop that keeps the process alive
/// with the screen off while the voice session runs. No iPhone microphone is
/// opened: DAT Speech listens on the glasses and replies play over A2DP.
@MainActor
final class SilentKeepAlive {
    private var engine: AVAudioEngine?

    var isRunning: Bool { engine != nil }

    func start() -> Bool {
        guard engine == nil else { return true }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.mixWithOthers])
            try session.setActive(true)
            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1),
                  let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100) else {
                return false
            }
            silence.frameLength = 44_100
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            try engine.start()
            player.scheduleBuffer(silence, at: nil, options: .loops)
            player.play()
            self.engine = engine
            return true
        } catch {
            return false
        }
    }

    func stop() {
        engine?.stop()
        engine = nil
    }
}
