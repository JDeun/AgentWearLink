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
/// with the screen off, so a dropped voice session can be rebuilt by the
/// silent recovery loop while the phone is locked. No iPhone microphone is
/// opened: DAT Speech listens on the glasses and replies play over A2DP.
///
/// Its lifecycle is independent of the voice session: it is started in the
/// foreground (iOS refuses to start playback from the background) whenever
/// listening is wanted, and stopped only when the user stops listening. It
/// restarts itself after an audio interruption (a call, Siri) or a media
/// services reset.
@MainActor
final class SilentKeepAlive {
    private var player: AVAudioPlayer?
    private var wanted = false
    private var observers: [NSObjectProtocol] = []
    var onEvent: ((String) -> Void)?

    var isRunning: Bool { player?.isPlaying == true }

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let ended = raw.flatMap(AVAudioSession.InterruptionType.init) == .ended
            MainActor.assumeIsolated { self?.handleInterruption(ended: ended) }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restart(reason: "media services reset") }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Glasses connecting over Bluetooth change the route; make sure
            // the loop is still playing afterwards.
            MainActor.assumeIsolated {
                guard let self, self.wanted, !self.isRunning else { return }
                self.restart(reason: "route change")
            }
        })
    }

    /// Idempotent. Returns whether the loop is playing.
    @discardableResult
    func start() -> Bool {
        wanted = true
        if isRunning { return true }
        return play()
    }

    func stop() {
        wanted = false
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func play() -> Bool {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.mixWithOthers])
            try session.setActive(true)
            let player = try AVAudioPlayer(data: SilentWAV.data())
            player.numberOfLoops = -1
            guard player.play() else { return false }
            self.player = player
            return true
        } catch {
            return false
        }
    }

    private func handleInterruption(ended: Bool) {
        guard wanted else { return }
        if ended { restart(reason: "interruption ended") } else { onEvent?("keep-alive interrupted") }
    }

    private func restart(reason: String) {
        guard wanted else { return }
        player?.stop()
        player = nil
        let ok = play()
        onEvent?("keep-alive restart (\(reason)): \(ok ? "ok" : "failed")")
    }
}
