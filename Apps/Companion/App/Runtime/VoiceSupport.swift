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
        if echo.suppresses(text, at: Date()) { return .ignore }
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
/// - Never touches the audio session (see `SilentKeepAlive`): replies mix
///   over other audio.
/// - Ends the echo-guard window at the real end of speech plus a tail.
@MainActor
final class ReplySpeaker: NSObject, SpeechSynthesizing, AVSpeechSynthesizerDelegate {
    private var synthesizer = AVSpeechSynthesizer()
    private let language: String?
    /// Chosen voice; empty uses the language's default voice.
    var voiceIdentifier = ""
    /// EXPERIMENT glasses-mic wake: the route is Bluetooth hands-free.
    var allowHandsFree = false
    var gate: WakeGateBox?
    /// Called when a reply could not be spoken because of the route.
    var onSilenced: (() -> Void)?
    var onSpoken: (() -> Void)?
    /// The last queued utterance finished (nothing left to say).
    var onIdle: (() -> Void)?
    var onEvent: ((String) -> Void)?
    var isSpeaking: Bool { synthesizer.isSpeaking }
    /// EXPERIMENT (default off), see `ReplyDuckingMode`.
    var duckingMode: ReplyDuckingMode = .off {
        didSet {
            guard duckingMode != oldValue else { return }
            onEvent?("reply ducking mode: \(duckingMode.rawValue)")
            recreate()
        }
    }
    /// Variant 2 only: toggles `.duckOthers` on the app session.
    var setDucking: ((Bool) -> Void)?

    init(language: String?) {
        self.language = language
        super.init()
        synthesizer.delegate = self
        configureSynthesizer()
    }

    /// After a media-services reset the old synthesizer is unusable.
    func recreate() {
        synthesizer.delegate = nil
        synthesizer.stopSpeaking(at: .immediate)
        synthesizer = AVSpeechSynthesizer()
        synthesizer.delegate = self
        configureSynthesizer()
    }

    private func configureSynthesizer() {
        // Variant 1: the synthesizer owns a separate session; ours is untouched.
        synthesizer.usesApplicationAudioSession = duckingMode != .separateSynthesizerSession
    }

    func speak(_ text: String) async {
        await speak(text, allowPhoneSpeaker: false)
    }

    /// `allowPhoneSpeaker` is only for the Settings voice preview, which the
    /// user starts with the phone in hand; replies never use the speaker.
    func speak(_ text: String, allowPhoneSpeaker: Bool) async {
        guard !text.isEmpty else { return }
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType).map(Self.kind)
        guard allowPhoneSpeaker || AudioRoutePolicy.canSpeakAloud(outputs: outputs, allowHandsFree: allowHandsFree) else {
            onEvent?("reply not spoken: route \(outputs)")
            onSilenced?()
            return
        }
        await gate?.beganSpeaking(text)
        // Default: no ducking. Changing the audio session while a DAT session
        // is held makes the glasses end it (dat-ios #292); replies mix over
        // music. The variants below exist only to be measured.
        if duckingMode != .off {
            onEvent?("reply start [\(duckingMode.rawValue)] otherAudio=\(AVAudioSession.sharedInstance().isOtherAudioPlaying)")
        }
        if duckingMode == .toggleDuckOthers { setDucking?(true) }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = (voiceIdentifier.isEmpty ? nil : AVSpeechSynthesisVoice(identifier: voiceIdentifier))
            ?? language.flatMap(AVSpeechSynthesisVoice.init(language:))
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
        guard !synthesizer.isSpeaking else { return }
        if duckingMode != .off {
            onEvent?("reply end [\(duckingMode.rawValue)] otherAudio=\(AVAudioSession.sharedInstance().isOtherAudioPlaying)")
        }
        if duckingMode == .toggleDuckOthers { setDucking?(false) }
        onIdle?()
    }

    /// Installed voices for the reply language, best first.
    func voiceOptions() -> [VoiceOption] {
        let all = AVSpeechSynthesisVoice.speechVoices().map { voice in
            VoiceOption(
                id: voice.identifier,
                name: voice.name,
                language: voice.language,
                quality: voice.quality == .premium ? .premium : voice.quality == .enhanced ? .enhanced : .standard,
                gender: voice.gender == .male ? .male : voice.gender == .female ? .female : .unspecified
            )
        }
        return VoiceCatalog.options(from: all, language: language ?? "ko-KR")
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
/// Audio-session rule (dat-ios #292): reconfiguring or re-activating the
/// AVAudioSession while a DAT session is held makes the glasses end that
/// session within ~300 ms. So the category is set once, the session is
/// activated before a DAT session is created, and while one is live only
/// the engine is restarted; activation waits until no DAT session exists.
/// Every audio-session call is logged (with the log's timestamp) so device
/// logs can be matched against session ends.
@MainActor
final class SilentKeepAlive {
    enum Event { case interruptionEnded, mediaServicesReset, routeChanged }

    private var engine: AVAudioEngine?
    /// Plays earcons through the same engine, so tones never need the audio
    /// session to change while a DAT session is live (dat-ios #292).
    private var cuePlayer: AVAudioPlayerNode?
    private var cueFormat: AVAudioFormat?
    private var wanted = false
    private var categoryConfigured = false
    /// Our best knowledge of whether the session is active.
    private var sessionActive = false
    private var watchdog: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    var onLog: ((String) -> Void)?
    var onEvent: ((Event) -> Void)?
    /// True while a DAT session exists (or is being created).
    var isDATSessionLive: () -> Bool = { false }

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
                // The system deactivated our session for the interruption.
                self.sessionActive = false
                if ended { self.onEvent?(.interruptionEnded) }
            }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onLog?("audio media services reset")
                self.engine = nil
                self.sessionActive = false
                self.categoryConfigured = false
                self.onEvent?(.mediaServicesReset)
            }
        })
        observers.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main
        ) { [weak self] note in
            let changed = note.object as AnyObject?
            MainActor.assumeIsolated {
                guard let self, let engine = self.engine, changed === engine else { return }
                // The engine stopped itself (e.g. route/format change): restart
                // the engine only, never the session.
                self.onLog?("keep-alive engine configuration changed — restarting engine")
                self.engine?.stop()
                self.engine = nil
                if self.wanted { self.startEngine() }
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
                // Only the engine; never the session.
                if self.wanted, !self.isRunning { self.startEngine() }
                self.onEvent?(.routeChanged)
            }
        })
    }

    /// Idempotent. Activates the session only if no DAT session is live,
    /// then starts the engine; the watchdog keeps retrying.
    func start() {
        wanted = true
        if watchdog == nil {
            watchdog = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(3))
                    guard let self, !Task.isCancelled else { return }
                    guard self.wanted else { continue }
                    if !self.sessionActive, !self.isDATSessionLive() {
                        self.activateSession(reason: "watchdog")
                    }
                    if !self.isRunning {
                        self.onLog?("keep-alive not running — restarting engine (watchdog)")
                        self.startEngine()
                    }
                }
            }
        }
        if !sessionActive, !isDATSessionLive() { activateSession(reason: "start") }
        startEngine()
    }

    /// Call right before creating a DAT session: the only safe moment to
    /// (re)activate the audio session.
    func prepareForDATSession() {
        guard wanted else { return }
        if !sessionActive { activateSession(reason: "before DAT session") }
        if !isRunning { startEngine() }
    }

    func stop() {
        wanted = false
        watchdog?.cancel()
        watchdog = nil
        engine?.stop()
        engine = nil
        guard sessionActive, !isDATSessionLive() else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            sessionActive = false
            onLog?("audio-session setActive(false) ok")
        } catch {
            onLog?("audio-session setActive(false) failed: \(error.localizedDescription)")
        }
    }

    private func activateSession(reason: String) {
        let session = AVAudioSession.sharedInstance()
        if !categoryConfigured {
            do {
                // Never .allowBluetoothHFP / .defaultToSpeaker.
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
                categoryConfigured = true
                onLog?("audio-session setCategory(.playback, .default, mixWithOthers) ok [\(reason)]")
            } catch {
                onLog?("audio-session setCategory failed [\(reason)]: \(error.localizedDescription)")
            }
        }
        do {
            try session.setActive(true)
            sessionActive = true
            onLog?("audio-session setActive(true) ok [\(reason)]")
        } catch {
            onLog?("audio-session setActive(true) failed [\(reason)]: \(error.localizedDescription)")
        }
    }

    /// EXPERIMENT variant 2 only (default off): toggles `.duckOthers` on the
    /// playback session around a reply. dat-ios #292 suggests this can end
    /// the DAT session; it is logged so that can be measured.
    func setExperimentalDucking(_ on: Bool) {
        let options: AVAudioSession.CategoryOptions = on ? [.mixWithOthers, .duckOthers] : [.mixWithOthers]
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: options)
            onLog?("audio-session setCategory(duckOthers=\(on)) ok [experiment, DAT live=\(isDATSessionLive())]")
        } catch {
            onLog?("audio-session setCategory(duckOthers=\(on)) failed: \(error.localizedDescription)")
        }
    }

    /// Plays a short tone over whatever else is playing. Returns false when
    /// the engine is not running (nothing is played).
    @discardableResult
    func play(_ earcon: Earcon) -> Bool {
        guard isRunning, let player = cuePlayer, let format = cueFormat else { return false }
        let mono = earcon.samples(sampleRate: format.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(mono.count)),
              let channels = buffer.floatChannelData else { return false }
        buffer.frameLength = AVAudioFrameCount(mono.count)
        for channel in 0..<Int(format.channelCount) {
            mono.withUnsafeBufferPointer { source in
                channels[channel].update(from: source.baseAddress!, count: mono.count)
            }
        }
        player.scheduleBuffer(buffer, completionHandler: nil)
        if !player.isPlaying { player.play() }
        return true
    }

    /// Engine only: never touches the session.
    private func startEngine() {
        if isRunning { return }
        engine?.stop()
        engine = nil
        cuePlayer = nil
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
        let player = AVAudioPlayerNode()
        let cueFormat = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: format.channelCount)
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: cueFormat)
        do {
            try engine.start()
            self.engine = engine
            self.cuePlayer = player
            self.cueFormat = cueFormat
            onLog?("keep-alive engine on")
        } catch {
            onLog?("keep-alive engine start failed: \(error.localizedDescription)")
        }
    }
}
