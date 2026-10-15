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
    /// The tap appends straight into the current request (append is
    /// thread-safe); no per-buffer Task, so PCM stays in order.
    private let requestBox = RecognitionRequestBox()
    private var task: SFSpeechRecognitionTask?
    /// Bumped for every new task (and on stop): callbacks carry the
    /// generation of the task that produced them.
    private var generation: UInt64 = 0
    private var errorsInARow = 0
    private var retry: Task<Void, Never>?
    private var lastPartial = ""
    private var lastChange = Date.distantPast
    private var taskStartedAt = Date.distantPast
    private var lastEngineAttempt = Date.distantPast
    private var watchdog: Task<Void, Never>?
    private var configurationObserver: NSObjectProtocol?
    private var running = false
    /// This adapter set the play-and-record category (restore it once).
    private var sessionConfigured = false

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
        // Without record permission the input delivers silence.
        var microphone = AVAudioApplication.shared.recordPermission
        if microphone == .undetermined {
            _ = await AVAudioApplication.requestRecordPermission()
            microphone = AVAudioApplication.shared.recordPermission
        }
        guard microphone == .granted else {
            throw AWLError.capabilityUnavailable("microphone permission not granted")
        }
        let session = AVAudioSession.sharedInstance()
        do {
            // No DAT session exists in this mode (dat-ios #292 does not apply).
            if session.category != .playAndRecord || !session.categoryOptions.contains(.allowBluetoothHFP) {
                try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP, .mixWithOthers])
            }
            sessionConfigured = true
            try session.setActive(true)
            if let hfp = session.availableInputs?.first(where: { $0.portType == .bluetoothHFP }) {
                try session.setPreferredInput(hfp)
            }
        } catch {
            restoreSession()
            throw AWLError.device("audio session for the glasses mic failed: \(error.localizedDescription)")
        }
        let input = session.currentRoute.inputs.map(\.portType.rawValue).joined(separator: "+")
        guard session.currentRoute.inputs.contains(where: { $0.portType == .bluetoothHFP }) else {
            restoreSession()
            throw AWLError.device("glasses microphone not available (input: \(input))")
        }
        log("glasses-mic wake: input \(input)")
        do {
            try startEngine()
        } catch {
            restoreSession()
            throw AWLError.device("glasses mic engine failed: \(error.localizedDescription)")
        }
        running = true
        // The engine stops itself on a route/format change (or another app's
        // audio); reinstall the tap and restart it, never the session.
        let engine = self.engine
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            Task { await self?.engineConfigurationChanged() }
        }
        startTask()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                await self?.tick()
            }
        }
    }

    func disconnect() async {
        let wasRunning = running
        running = false
        generation &+= 1
        watchdog?.cancel()
        watchdog = nil
        retry?.cancel()
        retry = nil
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        task?.cancel()
        task = nil
        requestBox.set(nil)
        if engine.isRunning { engine.stop() }
        if wasRunning { engine.inputNode.removeTap(onBus: 0) }
        restoreSession()
        continuation.finish()
    }

    /// Back to playback only, so music returns to A2DP quality. Once.
    private func restoreSession() {
        guard sessionConfigured else { return }
        sessionConfigured = false
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
    }

    private func startEngine() throws {
        lastEngineAttempt = Date()
        engine.inputNode.removeTap(onBus: 0)
        let format = engine.inputNode.outputFormat(forBus: 0)
        let box = requestBox
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            box.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            throw error
        }
    }

    private func engineConfigurationChanged() {
        guard running else { return }
        log("glasses-mic wake: engine configuration changed — restarting engine")
        restartEngine()
    }

    private func restartEngine() {
        if engine.isRunning { engine.stop() }
        do {
            try startEngine()
            // A new input format needs a new request.
            restartTask()
        } catch {
            // The watchdog tries again.
            log("glasses-mic wake: engine restart failed: \(error.localizedDescription)")
        }
    }

    private func startTask() {
        guard running, let recognizer else { return }
        retry?.cancel()
        retry = nil
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.contextualStrings = contextualPhrases
        request.taskHint = .dictation
        generation &+= 1
        let current = generation
        requestBox.set(request)
        lastPartial = ""
        lastChange = Date()
        taskStartedAt = Date()
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            let failure = error.map { ($0 as NSError).domain }
            let code = error.map { ($0 as NSError).code }
            Task { await self?.handle(text: text, final: final, failure: failure, code: code, generation: current) }
        }
    }

    /// Ends the current task (its late callbacks are ignored by generation)
    /// and starts a new one now.
    private func restartTask() {
        stopTask()
        startTask()
    }

    private func stopTask() {
        generation &+= 1
        requestBox.endAudio()
        requestBox.set(nil)
        task?.cancel()
        task = nil
    }

    /// - Parameter failure: the error domain when the task failed.
    private func handle(text: String?, final: Bool, failure: String?, code: Int?, generation callback: UInt64) async {
        guard GlassesMicRetry.isCurrent(callbackGeneration: callback, current: generation, running: running) else { return }
        if let text, text != lastPartial {
            lastPartial = text
            lastChange = Date()
            errorsInARow = 0
        }
        if failure != nil {
            await finishUtterance()
            guard GlassesMicRetry.isCurrent(callbackGeneration: callback, current: generation, running: running) else { return }
            if GlassesMicRetry.isQuietEnd(domain: failure, code: code, taskAge: Date().timeIntervalSince(taskStartedAt)) {
                restartTask()
                return
            }
            stopTask()
            errorsInARow += 1
            let delay = GlassesMicRetry.delay(afterErrors: errorsInARow)
            if errorsInARow == 1 || errorsInARow % 10 == 0 {
                log("glasses-mic wake: recognizer error \(errorsInARow)x — retrying in \(delay) s")
            }
            let expected = generation
            retry = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                await self?.retryTask(ifGeneration: expected)
            }
        } else if final {
            await finishUtterance()
            guard GlassesMicRetry.isCurrent(callbackGeneration: callback, current: generation, running: running) else { return }
            restartTask()
        }
    }

    private func retryTask(ifGeneration expected: UInt64) {
        guard running, generation == expected, task == nil else { return }
        startTask()
    }

    /// Ends an utterance after a short pause, recycles long tasks, and
    /// restarts an engine that stopped.
    private func tick() async {
        guard running else { return }
        let now = Date()
        if !engine.isRunning, now.timeIntervalSince(lastEngineAttempt) >= GlassesMicRetry.engineRestartSpacing {
            restartEngine()
            return
        }
        guard task != nil else { return } // backing off after an error
        if !lastPartial.isEmpty, now.timeIntervalSince(lastChange) >= Self.endOfUtterance {
            let before = generation
            await finishUtterance()
            guard running, generation == before else { return }
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

/// The current recognition request, shared with the audio tap thread.
final class RecognitionRequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func set(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        self.request = request
        lock.unlock()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        request?.append(buffer)
    }

    func endAudio() {
        lock.lock()
        defer { lock.unlock() }
        request?.endAudio()
    }
}
