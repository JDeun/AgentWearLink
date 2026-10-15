import AgentWearLinkCore
import AVFoundation
import Foundation
import Speech

/// EXPERIMENT (default off): two-stage wake without DAT Speech.
///
/// The glasses microphone reaches the iPhone over Bluetooth hands-free (HFP),
/// and iOS on-device speech recognition listens for the wake phrase. Only
/// the microphone and the radio run on the glasses; recognition runs on the
/// phone. Meta's SDK has no app-usable low-power keyword detector on the
/// glasses (dat-ios discussion #343), so this is the cheapest two-stage
/// design available to a third-party app.
///
/// Costs to measure: HFP turns music into call-quality audio while the mic is
/// open; the glasses' HFP uplink may still be expensive; on-device ASR costs
/// phone battery. No DAT session is opened in this mode (opening the HFP mic
/// next to a DAT session ended sessions in dat-ios #342).
actor GlassesMicSpeechAdapter: DeviceAdapter {
    nonisolated let capabilities: CapabilitySet = [.speechInput]

    private let locale: Locale
    private let contextualPhrases: [String]
    private let log: @Sendable (String) -> Void
    private var transcriptGate: (@Sendable (String) async -> String?)?

    private let engine = AVAudioEngine()
    private let recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var lastPartial = ""
    private var lastChange = Date.distantPast
    private var taskStartedAt = Date.distantPast
    private var watchdog: Task<Void, Never>?
    private var running = false

    private let continuation: AsyncStream<InteractionEvent>.Continuation
    private let stream: AsyncStream<InteractionEvent>

    /// A partial transcript unchanged this long ends the utterance.
    static let endOfUtterance: TimeInterval = 1.0
    /// Recognition tasks are recycled before iOS limits apply.
    static let taskLifetime: TimeInterval = 50

    init(language: String, contextualPhrases: [String], log: @escaping @Sendable (String) -> Void) {
        locale = Locale(identifier: language)
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: language))
        self.contextualPhrases = contextualPhrases
        self.log = log
        (stream, continuation) = AsyncStream.makeStream(of: InteractionEvent.self, bufferingPolicy: .bufferingNewest(16))
    }

    func setTranscriptGate(_ gate: (@Sendable (String) async -> String?)?) {
        transcriptGate = gate
    }

    nonisolated func events() -> AsyncStream<InteractionEvent> { stream }

    func connect() async throws {
        guard let recognizer, recognizer.supportsOnDeviceRecognition else {
            throw AWLError.capabilityUnavailable("on-device speech recognition unavailable for \(locale.identifier)")
        }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw AWLError.capabilityUnavailable("speech recognition not authorized")
        }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP, .mixWithOthers])
            try session.setActive(true)
            if let hfp = session.availableInputs?.first(where: { $0.portType == .bluetoothHFP }) {
                try session.setPreferredInput(hfp)
            }
        } catch {
            throw AWLError.device("audio session for the glasses mic failed: \(error.localizedDescription)")
        }
        let input = session.currentRoute.inputs.map(\.portType.rawValue).joined(separator: "+")
        guard session.currentRoute.inputs.contains(where: { $0.portType == .bluetoothHFP }) else {
            throw AWLError.device("glasses microphone not available (input: \(input))")
        }
        log("glasses-mic wake: input \(input)")
        let format = engine.inputNode.outputFormat(forBus: 0)
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            Task { await self.append(buffer) }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            throw AWLError.device("glasses mic engine failed: \(error.localizedDescription)")
        }
        running = true
        startTask()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                await self?.tick()
            }
        }
    }

    func disconnect() async {
        running = false
        watchdog?.cancel()
        watchdog = nil
        task?.cancel()
        task = nil
        request = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        // Back to playback only, so music returns to A2DP quality.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
        continuation.finish()
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        request?.append(buffer)
    }

    private func startTask() {
        guard running, let recognizer else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.contextualStrings = contextualPhrases
        request.taskHint = .dictation
        self.request = request
        lastPartial = ""
        lastChange = Date()
        taskStartedAt = Date()
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            let failed = error != nil
            Task { await self?.handle(text: text, final: final, failed: failed) }
        }
    }

    private func restartTask() {
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        startTask()
    }

    private func handle(text: String?, final: Bool, failed: Bool) async {
        if let text, text != lastPartial {
            lastPartial = text
            lastChange = Date()
        }
        if final || failed {
            await finishUtterance()
            restartTask()
        }
    }

    /// Ends an utterance after a short pause, and recycles long tasks.
    private func tick() async {
        guard running else { return }
        let now = Date()
        if !lastPartial.isEmpty, now.timeIntervalSince(lastChange) >= Self.endOfUtterance {
            await finishUtterance()
            restartTask()
        } else if lastPartial.isEmpty, now.timeIntervalSince(taskStartedAt) >= Self.taskLifetime {
            restartTask()
        }
    }

    private func finishUtterance() async {
        let text = lastPartial.trimmingCharacters(in: .whitespacesAndNewlines)
        lastPartial = ""
        guard !text.isEmpty else { return }
        guard let gate = transcriptGate else {
            continuation.yield(.text(InteractionID(), text))
            return
        }
        guard let request = await gate(text) else { return }
        continuation.yield(.text(InteractionID(), request))
    }
}
