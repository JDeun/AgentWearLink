import AgentWearLinkAppleOutput
import AVFoundation
import Foundation

/// EXPERIMENT (locked-phone voice): keep-alive modelled on a measured
/// locked-phone reference. `.playback`, mode `.default`, `.mixWithOthers`;
/// silence from an AVAudioSourceNode writing zeros (never ends by itself);
/// a 3 s watchdog restarts it whenever it is wanted and not running.
/// Observes interruptions, media-services resets and route changes, and
/// reports them to the host (calls end the DAT session on current firmware).
@MainActor
final class AWLSilentKeepAlive {
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
                    // Regardless of shouldResume: it is often missing after a call.
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

    /// Ducks other audio (music) while a reply is spoken; stays active.
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
        // Never .allowBluetoothHFP / .defaultToSpeaker: replies stay on A2DP.
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
            let outputs = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType.rawValue)
            onLog?("keep-alive on route=\(outputs)")
        } catch {
            onLog?("keep-alive start failed: \(error.localizedDescription)")
        }
    }
}

/// Speaks replies only into the ear (A2DP / BLE / headphones, never the
/// iPhone speaker), ducks other audio while speaking, and ends the echo
/// window on the synthesizer's real didFinish/didCancel.
@MainActor
final class AWLReplySpeaker: NSObject, SpeechSynthesizing, AVSpeechSynthesizerDelegate {
    private var synthesizer = AVSpeechSynthesizer()
    private let language: String?
    var gate: AWLWakeGateBox?
    var onLog: ((String) -> Void)?
    var setDucking: ((Bool) -> Void)?

    init(language: String?) {
        self.language = language
        super.init()
        synthesizer.delegate = self
    }

    func recreate() {
        synthesizer.delegate = nil
        synthesizer.stopSpeaking(at: .immediate)
        synthesizer = AVSpeechSynthesizer()
        synthesizer.delegate = self
        setDucking?(false)
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
        setDucking?(true)
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
        if !synthesizer.isSpeaking { setDucking?(false) }
    }
}
