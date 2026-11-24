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
    private let onLeaseEnd: @Sendable (HFPListeningLease.End) -> Void
    private var lease: HFPListeningLease
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
    private var observers: [NSObjectProtocol] = []
    private var leaseWatch: Task<Void, Never>?
    private var running = false
    private var retired = false
    private var tapInstalled = false
    private var engineRestarts = 0
    private var inputUID: String?
    private struct PriorAudioSession {
        let category: AVAudioSession.Category
        let mode: AVAudioSession.Mode
        let options: AVAudioSession.CategoryOptions
    }
    private var priorAudioSession: PriorAudioSession?
    private let installedOptions: AVAudioSession.CategoryOptions = [.allowBluetoothHFP, .mixWithOthers]

    private nonisolated let eventSource = BoundedDeviceEventSource(bufferLimit: 16)
    private var eventGeneration: UInt64?

    /// A partial transcript unchanged this long ends the utterance.
    static let endOfUtterance: TimeInterval = 1.0
    /// Recognition tasks are recycled before iOS limits apply.
    static let taskLifetime: TimeInterval = 50

    init(
        language: String, contextualPhrases: [String], lease: HFPListeningLease,
        log: @escaping @Sendable (String) -> Void,
        onLeaseEnd: @escaping @Sendable (HFPListeningLease.End) -> Void
    ) {
        locale = Locale(identifier: language)
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: language))
        self.contextualPhrases = contextualPhrases
        self.log = log
        self.lease = lease
        self.onLeaseEnd = onLeaseEnd
    }

    func setTranscriptGate(_ gate: (@Sendable (String) async -> String?)?) {
        transcriptGate = gate
    }

    nonisolated func events() -> AsyncStream<InteractionEvent> { eventSource.stream() }

    func connect() async throws {
        guard !retired, !running, lease.isWithinHardLimit(), !Task.isCancelled else {
            throw CancellationError()
        }
        guard let recognizer, recognizer.supportsOnDeviceRecognition else {
            throw AWLError.capabilityUnavailable("on-device speech recognition unavailable")
        }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw AWLError.capabilityUnavailable("speech recognition not authorized")
        }
        // Permission UI is a separate explicit host action; no prompt from
        // an automatic connection or a resumed lease.
        guard AVAudioApplication.shared.recordPermission == .granted else {
            throw AWLError.capabilityUnavailable("microphone permission not granted")
        }

        let session = AVAudioSession.sharedInstance()
        guard !session.isOtherAudioPlaying, session.category == .playback else {
            throw AWLError.capabilityUnavailable("audio route occupied")
        }
        eventGeneration = eventSource.currentGeneration()
        priorAudioSession = PriorAudioSession(category: session.category, mode: session.mode, options: session.categoryOptions)
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: installedOptions)
            try session.setActive(true)
            // Never fall back to the phone mic or choose between ambiguous
            // HFP accessories. Only one HFP input may be admitted.
            let inputs = session.availableInputs?.filter { $0.portType == .bluetoothHFP } ?? []
            guard inputs.count == 1, let hfp = inputs.first else {
                throw AWLError.capabilityUnavailable("unambiguous HFP input unavailable")
            }
            inputUID = hfp.uid
            try session.setPreferredInput(hfp)
            guard routeIsOwned(), !session.isOtherAudioPlaying, lease.isWithinHardLimit() else {
                throw AWLError.capabilityUnavailable("HFP input not ready")
            }
            try startEngine()
        } catch {
            retire(.connectionFailed, notify: false)
            throw AWLError.device("glasses microphone activation failed")
        }
        running = true
        log("HFP lease started: bluetoothHFP input")
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in Task { await self?.engineConfigurationChanged() } })
        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in Task { await self?.checkLease() } })
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: nil
        ) { [weak self] note in
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard type == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { await self?.retire(.interrupted) }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil
        ) { [weak self] _ in Task { await self?.retire(.interrupted) } })
        startTask()
        // Separate from the consumer/async transcript gate. Even if a gate
        // suspends, route/idle/deadline checking can still retire this actor.
        leaseWatch = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self, await self.checkLease() else { return }
            }
        }
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                await self?.tick()
            }
        }
    }

    func disconnect() async {
        retire(.stopped, notify: false)
    }

    func endLease(_ reason: HFPListeningLease.End) {
        retire(reason)
    }

    private func routeIsOwned() -> Bool {
        let session = AVAudioSession.sharedInstance()
        guard let inputUID, session.category == .playAndRecord,
              session.mode == .default,
              session.currentRoute.inputs.count == 1,
              let input = session.currentRoute.inputs.first else { return false }
        return input.portType == .bluetoothHFP && input.uid == inputUID
    }

    @discardableResult
    private func checkLease() -> Bool {
        guard running, !retired else { return false }
        if let reason = lease.end(at: .now, routeAvailable: routeIsOwned(),
                                  competingAudio: AVAudioSession.sharedInstance().isOtherAudioPlaying) {
            retire(reason)
            return false
        }
        return true
    }

    private func retire(_ reason: HFPListeningLease.End, notify: Bool = true) {
        guard !retired else { return }
        retired = true
        running = false
        generation &+= 1
        leaseWatch?.cancel()
        leaseWatch = nil
        watchdog?.cancel()
        watchdog = nil
        retry?.cancel()
        retry = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        stopTask()
        if engine.isRunning { engine.stop() }
        removeInputTap()
        restoreSession()
        eventSource.finish(generation: eventGeneration)
        eventGeneration = nil
        lastPartial = ""
        log("HFP lease ended: \(reason.rawValue)")
        if notify { onLeaseEnd(reason) }
    }

    /// Clear only our preferred input and restore the previously owned
    /// playback category. Host owns playback engine activation/deactivation;
    /// never override a session configuration changed by another owner.
    private func restoreSession() {
        guard let prior = priorAudioSession else { return }
        priorAudioSession = nil
        let session = AVAudioSession.sharedInstance()
        if let inputUID, session.preferredInput?.uid == inputUID {
            do {
                try session.setPreferredInput(nil)
                log("HFP preferred input released")
            } catch { log("HFP preferred input release failed") }
        }
        inputUID = nil
        guard session.category == .playAndRecord, session.mode == .default,
              session.categoryOptions.contains(.allowBluetoothHFP) else {
            log("HFP category changed externally; not restoring")
            return
        }
        do {
            try session.setCategory(prior.category, mode: prior.mode, options: prior.options)
            log("HFP playback category restored")
        } catch { log("HFP playback category restore failed") }
    }

    private func removeInputTap() {
        guard tapInstalled else { return }
        tapInstalled = false
        engine.inputNode.removeTap(onBus: 0)
    }

    private func startEngine() throws {
        lastEngineAttempt = Date()
        removeInputTap()
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AWLError.capabilityUnavailable("invalid HFP input format")
        }
        let box = requestBox
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            box.append(buffer)
        }
        tapInstalled = true
        engine.prepare()
        do {
            try engine.start()
        } catch {
            removeInputTap()
            throw error
        }
    }

    private func engineConfigurationChanged() {
        guard checkLease() else { return }
        // Startup route changes can emit a delayed configuration event.
        // Never restart a healthy engine on an old notification.
        if !engine.isRunning { restartEngine() }
    }

    private func restartEngine() {
        guard checkLease() else { return }
        guard engineRestarts < HFPListeningLease.maximumEngineRestarts else {
            retire(.engineFailed)
            return
        }
        engineRestarts += 1
        if engine.isRunning { engine.stop() }
        stopTask()
        do {
            try startEngine()
            startTask()
        } catch {
            log("HFP engine restart failed")
            if engineRestarts >= HFPListeningLease.maximumEngineRestarts { retire(.engineFailed) }
        }
    }

    private func startTask() {
        guard checkLease(), let recognizer else { return }
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
        guard GlassesMicRetry.isCurrent(callbackGeneration: callback, current: generation, running: running),
              checkLease() else { return }
        if let text, text != lastPartial {
            lastPartial = text
            lastChange = Date()
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lease.noteActivity(at: .now)
                errorsInARow = 0
            }
        }
        if failure != nil {
            // An error is not a final transcript. Do not dispatch partial
            // words as a command during route loss or recognition failure.
            lastPartial = ""
            if GlassesMicRetry.isQuietEnd(domain: failure, code: code, taskAge: Date().timeIntervalSince(taskStartedAt)) {
                restartTask()
                return
            }
            stopTask()
            errorsInARow += 1
            guard errorsInARow < HFPListeningLease.maximumRecognizerErrors else {
                retire(.recognitionFailed)
                return
            }
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
        guard generation == expected, task == nil, checkLease() else { return }
        startTask()
    }

    /// Ends an utterance after a short pause, recycles long tasks, and
    /// restarts an engine that stopped.
    private func tick() async {
        guard checkLease() else { return }
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
        guard !text.isEmpty, checkLease() else { return }
        let owner = generation
        let request: String?
        if let gate = transcriptGate { request = await gate(text) }
        else { request = text }
        guard let request, owner == generation, checkLease(), !Task.isCancelled else { return }
        eventSource.yield(.text(InteractionID(), request), generation: eventGeneration)
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
