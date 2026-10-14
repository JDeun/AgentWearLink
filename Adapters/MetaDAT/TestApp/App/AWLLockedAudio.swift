import AgentWearLinkAppleOutput
import AVFoundation
import Foundation

/// EXPERIMENT (locked-phone voice): keep-alive modelled on a measured
/// locked-phone reference: `.playback`, mode `.default`, `.mixWithOthers`;
/// silence from an AVAudioSourceNode writing zeros; a 3 s watchdog.
///
/// Audio-session rule (dat-ios #292): reconfiguring or re-activating the
/// AVAudioSession while a DAT session is held makes the glasses end it
/// ~170–300 ms later. The category is set once; the session is activated
/// only when no DAT session exists (right before one is created); while one
/// is live only the engine is restarted. Every session call is logged.
@MainActor
final class AWLSilentKeepAlive {
    enum Event { case interruptionEnded, mediaServicesReset, routeChanged }

    private var engine: AVAudioEngine?
    private var wanted = false
    private var categoryConfigured = false
    private var sessionActive = false
    private var watchdog: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    var onLog: ((String) -> Void)?
    var onEvent: ((Event) -> Void)?
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
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
                .map(\.portType.rawValue).joined(separator: ",")
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onLog?("audio route reason=\(reason.map(String.init) ?? "-") outputs=\(outputs)")
                if self.wanted, !self.isRunning { self.startEngine() }
                self.onEvent?(.routeChanged)
            }
        })
    }

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

    /// The only safe moment to (re)activate: right before a DAT session.
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

    /// EXPERIMENT E variant 2 only (default off): toggle `.duckOthers` on the
    /// playback session around a reply. #292 suggests this ends the session;
    /// logged so tonight's "Session ended by device" can be correlated.
    func setExperimentalDucking(_ on: Bool) {
        let options: AVAudioSession.CategoryOptions = on ? [.mixWithOthers, .duckOthers] : [.mixWithOthers]
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: options)
            onLog?("audio-session setCategory(duckOthers=\(on)) ok [experiment, DAT live=\(isDATSessionLive())]")
        } catch {
            onLog?("audio-session setCategory(duckOthers=\(on)) failed: \(error.localizedDescription)")
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

    /// Engine only: never touches the session.
    private func startEngine() {
        if isRunning { return }
        engine?.stop()
        engine = nil
        let engine = AVAudioEngine()
        var format = engine.mainMixerNode.outputFormat(forBus: 0)
        if format.sampleRate == 0 || format.channelCount == 0,
           let fallback = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2) {
            format = fallback
        }
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
            onLog?("keep-alive engine on")
        } catch {
            onLog?("keep-alive engine start failed: \(error.localizedDescription)")
        }
    }
}

/// EXPERIMENT E: reply ducking (default off).
enum AWLReplyDuckingMode: String, CaseIterable {
    case off
    /// AVSpeechSynthesizer.usesApplicationAudioSession = false.
    case separateSynthesizerSession
    /// Toggle .duckOthers on the app's playback session around a reply.
    case toggleDuckOthers
}

/// Speaks replies only into the ear (A2DP / BLE / headphones, never the
/// iPhone speaker) and ends the echo window on the synthesizer's real
/// didFinish/didCancel. Ducking is an opt-in experiment (EXPERIMENT E).
@MainActor
final class AWLReplySpeaker: NSObject, SpeechSynthesizing, AVSpeechSynthesizerDelegate {
    private var synthesizer = AVSpeechSynthesizer()
    private let language: String?
    var gate: AWLWakeGateBox?
    var onLog: ((String) -> Void)?
    var setDucking: ((Bool) -> Void)?
    var duckingMode: AWLReplyDuckingMode = .off {
        didSet {
            guard duckingMode != oldValue else { return }
            onLog?("reply ducking mode: \(duckingMode.rawValue)")
            recreate()
        }
    }

    init(language: String?) {
        self.language = language
        super.init()
        synthesizer.delegate = self
        configureSynthesizer()
    }

    private func configureSynthesizer() {
        synthesizer.usesApplicationAudioSession = duckingMode != .separateSynthesizerSession
    }

    func recreate() {
        synthesizer.delegate = nil
        synthesizer.stopSpeaking(at: .immediate)
        synthesizer = AVSpeechSynthesizer()
        synthesizer.delegate = self
        configureSynthesizer()
        onLog?("speech synthesizer recreated")
    }

    static func canSpeakAloud(_ outputs: [AVAudioSession.Port]) -> Bool {
        outputs.contains { [.bluetoothA2DP, .bluetoothLE, .headphones].contains($0) }
    }

    func speak(_ text: String) async {
        guard !text.isEmpty else { return }
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType)
        guard Self.canSpeakAloud(outputs) else {
            onLog?("reply not spoken (route \(outputs.map(\.rawValue))) — read it in Telegram")
            return
        }
        await gate?.beganSpeaking(text)
        // Default: no ducking (never touch the session while DAT is live).
        if duckingMode != .off {
            onLog?("reply start [\(duckingMode.rawValue)] otherAudio=\(AVAudioSession.sharedInstance().isOtherAudioPlaying)")
        }
        if duckingMode == .toggleDuckOthers { setDucking?(true) }
        let utterance = AVSpeechUtterance(string: text)
        if let language { utterance.voice = AVSpeechSynthesisVoice(language: language) }
        synthesizer.speak(utterance)
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
            onLog?("reply end [\(duckingMode.rawValue)] otherAudio=\(AVAudioSession.sharedInstance().isOtherAudioPlaying)")
        }
        if duckingMode == .toggleDuckOthers { setDucking?(false) }
    }
}
