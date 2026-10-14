import AgentWearLinkAppleOutput
import AgentWearLinkCore
import AVFoundation
import Foundation

/// Owns the wake-phrase gate on one actor, shared by the DAT transcript
/// callback, the double-tap handler and the reply speaker (echo guard).
actor WakeGateBox {
    private var gate: AWLWakePhraseGate
    private var echo = EchoWindow()

    init(phrases: [String]) {
        gate = AWLWakePhraseGate(wakePhrases: phrases)
    }

    func replacePhrases(_ phrases: [String]) {
        gate = AWLWakePhraseGate(wakePhrases: phrases)
    }

    func evaluate(_ text: String) -> AWLWakePhraseGate.Decision {
        // The app's own reply echoing into the glasses microphone.
        if echo.suppresses(at: Date()) { return .ignore }
        return gate.evaluate(text)
    }

    func arm() { gate.arm() }
    func beganSpeaking(_ text: String) { echo.beganSpeaking(text, at: Date()) }
    func finishedSpeaking() { echo.finishedSpeaking(at: Date()) }
}

/// Speaks replies into the glasses, and only there.
///
/// - Route guard: speaks only when the output is Bluetooth A2DP/LE or
///   headphones; never out of the iPhone speaker. It never asks for HFP or
///   the speaker (`.allowBluetoothHFP` / `.defaultToSpeaker` are not used).
/// - Ducks other audio (music) while speaking and restores plain mixing
///   when the utterance finishes, using the synthesizer delegate.
/// - Ends the echo-guard window at the real end of speech plus a tail.
@MainActor
final class ReplySpeaker: NSObject, SpeechSynthesizing, AVSpeechSynthesizerDelegate {
    private var synthesizer = AVSpeechSynthesizer()
    private let language: String?
    var gate: WakeGateBox?
    /// Called when a reply could not be spoken because of the route.
    var onSilenced: (() -> Void)?
    var onSpoken: (() -> Void)?
    var onEvent: ((String) -> Void)?
    var setDucking: ((Bool) -> Void)?

    init(language: String?) {
        self.language = language
        super.init()
        synthesizer.delegate = self
    }

    /// After a media-services reset the old synthesizer is unusable.
    func recreate() {
        synthesizer.delegate = nil
        synthesizer.stopSpeaking(at: .immediate)
        synthesizer = AVSpeechSynthesizer()
        synthesizer.delegate = self
        setDucking?(false)
    }

    func speak(_ text: String) async {
        guard !text.isEmpty else { return }
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType).map(Self.kind)
        guard AudioRoutePolicy.canSpeakAloud(outputs: outputs) else {
            onEvent?("reply not spoken: route \(outputs)")
            onSilenced?()
            return
        }
        await gate?.beganSpeaking(text)
        setDucking?(true)
        let utterance = AVSpeechUtterance(string: text)
        if let language { utterance.voice = AVSpeechSynthesisVoice(language: language) }
        synthesizer.speak(utterance)
        onSpoken?()
    }

    func stop() async {
        synthesizer.stopSpeaking(at: .immediate)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.utteranceEnded() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.utteranceEnded() }
    }

    private func utteranceEnded() {
        Task { await gate?.finishedSpeaking() }
        // More chunks may be queued; restore mixing only when all are done.
        if !synthesizer.isSpeaking { setDucking?(false) }
    }

    static func kind(_ port: AVAudioSession.Port) -> AudioOutputKind {
        switch port {
        case .bluetoothA2DP: .bluetoothA2DP
        case .bluetoothLE: .bluetoothLE
        case .headphones: .headphones
        case .bluetoothHFP: .bluetoothHFP
        case .builtInSpeaker: .builtInSpeaker
        case .builtInReceiver: .builtInReceiver
        default: .other
        }
    }
}

/// Silence played continuously so iOS keeps the app running with the screen
/// locked (without it the app is suspended ~2 s after locking), modelled on
/// a measured locked-phone reference. `.playback` + `.mixWithOthers`: never
/// interrupts music or navigation. No microphone is opened: DAT Speech
/// listens on the glasses.
///
/// Its lifecycle is independent of the voice session: wanted whenever
/// listening is wanted, stopped only when the user stops listening. A 3 s
/// watchdog restarts the engine whenever it is not running (interruption,
/// route change, a background launch where activation first failed).
@MainActor
final class SilentKeepAlive {
    enum Event { case interruptionEnded, mediaServicesReset, routeChanged }

    private var engine: AVAudioEngine?
    private var wanted = false
    private var ducking = false
    private var watchdog: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    var onLog: ((String) -> Void)?
    var onEvent: ((Event) -> Void)?

    var isRunning: Bool { engine?.isRunning ?? false }

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init)
            let reason = note.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt
            MainActor.assumeIsolated {
                guard let self else { return }
                let ended = type == .ended
                self.onLog?("audio interruption \(ended ? "ended" : "began") reason=\(reason.map(String.init) ?? "-")")
                if ended {
                    self.restartIfWanted()
                    self.onEvent?(.interruptionEnded)
                }
            }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onLog?("audio media services reset")
                self.engine = nil
                self.restartIfWanted()
                self.onEvent?(.mediaServicesReset)
            }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
                .map(\.portType.rawValue).joined(separator: ",")
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onLog?("audio route reason=\(reason.map(String.init) ?? "-") outputs=\(outputs)")
                self.restartIfWanted()
                self.onEvent?(.routeChanged)
            }
        })
    }

    /// Idempotent. Also starts the watchdog, which keeps retrying.
    func start() {
        wanted = true
        if watchdog == nil {
            watchdog = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(3))
                    guard let self, !Task.isCancelled else { return }
                    if self.wanted, !self.isRunning {
                        self.onLog?("keep-alive not running — restarting (watchdog)")
                        self.startEngine()
                    }
                }
            }
        }
        startEngine()
    }

    func stop() {
        wanted = false
        watchdog?.cancel()
        watchdog = nil
        engine?.stop()
        engine = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Ducks other audio while a reply is spoken; the session stays active.
    func setDucking(_ on: Bool) {
        guard on != ducking else { return }
        ducking = on
        do {
            try configureSession()
        } catch {
            onLog?("audio ducking \(on ? "on" : "off") failed: \(error.localizedDescription)")
        }
    }

    private func restartIfWanted() {
        guard wanted, !isRunning else { return }
        startEngine()
    }

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        let options: AVAudioSession.CategoryOptions = ducking ? [.mixWithOthers, .duckOthers] : [.mixWithOthers]
        try session.setCategory(.playback, mode: .default, options: options)
        try session.setActive(true)
    }

    private func startEngine() {
        if isRunning { return }
        engine?.stop()
        engine = nil
        do {
            try configureSession()
        } catch {
            onLog?("keep-alive session failed: \(error.localizedDescription)")
        }
        let engine = AVAudioEngine()
        var format = engine.mainMixerNode.outputFormat(forBus: 0)
        if format.sampleRate == 0 || format.channelCount == 0,
           let fallback = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2) {
            format = fallback
        }
        // Runs on the audio render thread: writes zeros, never ends by itself.
        let source = AVAudioSourceNode(format: format) { @Sendable _, _, _, audioBufferList -> OSStatus in
            for buffer in UnsafeMutableAudioBufferListPointer(audioBufferList) {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
            self.engine = engine
            onLog?("keep-alive on")
        } catch {
            onLog?("keep-alive start failed: \(error.localizedDescription)")
        }
    }
}
