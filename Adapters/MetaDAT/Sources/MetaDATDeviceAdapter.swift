import Foundation
import AgentWearLinkCore
import MWDATCore
import MWDATSpeech
import MWDATInputs

struct MetaDATDeviceSelectionCandidate: Equatable, Sendable {
    let identifier: String
    let rank: Int
}

enum MetaDATDeviceSelectionPolicy {
    static func selectedIdentifier(
        from candidates: [MetaDATDeviceSelectionCandidate]
    ) -> String? {
        candidates.min { lhs, rhs in
            if lhs.rank != rhs.rank {
                return lhs.rank < rhs.rank
            }
            return lhs.identifier < rhs.identifier
        }?.identifier
    }
}

struct MetaDATSessionGenerationFence: Sendable {
    private(set) var current: UInt64 = 0

    mutating func begin() -> UInt64 {
        current &+= 1
        return current
    }

    func owns(_ generation: UInt64) -> Bool {
        current == generation
    }

    @discardableResult
    mutating func retire(ifOwned generation: UInt64? = nil) -> Bool {
        if let generation, generation != current {
            return false
        }
        current &+= 1
        return true
    }
}

/// A concurrent second caller must never treat a still-pending vendor session
/// handshake as a successful connect. Re-entry on a ready session remains
/// idempotent; the in-progress check intentionally takes precedence.
enum MetaDATConnectAdmission {
    static func shouldStart(connecting: Bool, sessionActive: Bool) throws -> Bool {
        guard !connecting else {
            throw AWLError.device("Meta DAT session connection is already in progress")
        }
        return !sessionActive
    }
}

final class MetaDATDeviceEventSource: @unchecked Sendable {
    private struct Subscription {
        let generation: UInt64
        let continuation: AsyncStream<InteractionEvent>.Continuation
    }

    private let lock = NSLock()
    private let bufferLimit: Int
    private var nextGeneration: UInt64 = 0
    private var subscription: Subscription?

    init(bufferLimit: Int) {
        precondition(bufferLimit > 0)
        self.bufferLimit = bufferLimit
    }

    func stream() -> AsyncStream<InteractionEvent> {
        AsyncStream(
            bufferingPolicy: .bufferingNewest(bufferLimit)
        ) { continuation in
            lock.lock()
            nextGeneration &+= 1
            let generation = nextGeneration
            let previous = subscription
            subscription = Subscription(
                generation: generation,
                continuation: continuation
            )
            lock.unlock()

            continuation.onTermination = { [weak self] _ in
                self?.remove(generation: generation)
            }
            previous?.continuation.finish()
        }
    }

    func yield(_ event: InteractionEvent) {
        lock.lock()
        let active = subscription
        lock.unlock()

        guard let active else { return }

        switch active.continuation.yield(event) {
        case .enqueued:
            break
        case .dropped:
            _ = active.continuation.yield(
                .failed(
                    event.interactionID,
                    .overloaded("Meta DAT device event buffer capacity exceeded")
                )
            )
            retire(generation: active.generation)
        case .terminated:
            remove(generation: active.generation)
        @unknown default:
            retire(generation: active.generation)
        }
    }

    private func retire(generation: UInt64) {
        let continuation: AsyncStream<InteractionEvent>.Continuation?

        lock.lock()
        if subscription?.generation == generation {
            continuation = subscription?.continuation
            subscription = nil
        } else {
            continuation = nil
        }
        lock.unlock()

        continuation?.finish()
    }

    private func remove(generation: UInt64) {
        lock.lock()
        if subscription?.generation == generation {
            subscription = nil
        }
        lock.unlock()
    }
}

/// First concrete device adapter for Meta Wearables DAT.
///
/// This target is intentionally iOS/vendor-specific and must be compiled only
/// from an iOS reference app that links MWDATCore. The root AWL Core package
/// does not depend on Meta DAT.
public actor MetaDATDeviceAdapter: SnapshotCapturingDevice {
    public static let defaultEventBufferLimit = 64

    private nonisolated let liveCapabilities = MetaDATLiveCapabilitySource()

    /// Capability snapshots reflect the currently usable production surfaces.
    /// Raw audio remains unavailable: DAT Speech yields normalized on-device
    /// transcripts rather than exposing microphone PCM through this adapter.
    public nonisolated var capabilities: CapabilitySet {
        liveCapabilities.value
    }

    private let wearables: any WearablesInterface
    // Independent of DeviceSession: host may start Voice Invocation before
    // connecting a camera/Speech media session.
    private var voiceInvocationChannel: MetaDATVoiceInvocationChannel?
    private var voiceStartFence = MetaDATVoiceListenerStartFence()
    private var deviceSession: DeviceSession?
    private let applicationLifecycle: MetaDATApplicationLifecycle?
    private let diagnostics: AWLDiagnosticRecorder?
    private var applicationPhaseTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?
    private var errorTask: Task<Void, Never>?
    private var registrationTask: Task<Void, Never>?
    private var deviceMonitorTask: Task<Void, Never>?
    private var selectedDeviceListenerTask: Task<Void, Never>?
    private var speechTask: Task<Void, Never>?
    private var speech: Speech?
    private var speechErrorToken: (any AnyListenerToken)?
    private var speechStateToken: (any AnyListenerToken)?
    private var speechRestartAttempts = 0
    /// Speech deliberately stopped by the host (glasses taken off/folded):
    /// the DeviceSession and the attached Speech are kept, only Speech is
    /// stopped, so no new session start is needed when the glasses are worn
    /// again (a session ended by a doff can refuse new starts, dat-ios #292).
    private var speechPaused = false
    private var speechLocaleToken: (any AnyListenerToken)?
    /// Speech stall watchdog (MetaDATSpeechStallPolicy).
    private var lastTranscriptEventAt: ContinuousClock.Instant?
    private var lastNonEmptyTranscriptAt: ContinuousClock.Instant?
    private var speechEventCount = 0
    private var speechNonEmptyCount = 0
    private var speechStatsChecks = 0
    private var speechStallTask: Task<Void, Never>?
    private var speechStallRestarting = false
    private var speechStallRestarts = 0
    /// Empty-only restarts since the last non-empty transcript (backoff).
    private var emptyOnlyRestartsInARow = 0
    /// Last fresh Speech start (connect, resume, session resume).
    private var speechFreshStartAt: ContinuousClock.Instant?
    private var sessionIsStarted = true
    private var inputs: Inputs?
    private var inputsTask: Task<Void, Never>?
    private var transcriptGate: (@Sendable (String) async -> String?)?
    private var glassesInputHandler: (@Sendable (_ isSelect: Bool, _ description: String) async -> Void)?
    private var activityLogger: (@Sendable (String) -> Void)?
    private let speechTranscriptStream = MetaDATSpeechTranscriptStream()
    private let transcriptDeduplicator = MetaDATFinalTranscriptDeduplicator()
    private let finalTranscriptFilter = MetaDATFinalTranscriptFilter()
    private let cameraSnapshotController: MetaDATCameraSnapshotController
    private nonisolated let eventSource: MetaDATDeviceEventSource
    private var generationFence = MetaDATSessionGenerationFence()
    private var selectedDeviceLinkLossGate = MetaDATSelectedDeviceLinkLossGate()
    private var connecting = false
    private var stopping = false
    // Opt-in only: acknowledging LaunchApp may start media *after* the response
    // handle returns, and only while this app is foreground.
    private var foregroundMediaActivationOnVoiceLaunch = false
    private var pendingVoiceMediaLease: UInt64?
    private var voicePhaseTask: Task<Void, Never>?
    private let connectTimeout: Duration

    public init(
        wearables: any WearablesInterface = Wearables.shared,
        connectTimeout: Duration = .seconds(15),
        eventBufferLimit: Int = MetaDATDeviceAdapter.defaultEventBufferLimit,
        snapshotTimeout: Duration = .seconds(5),
        snapshotMode: MetaDATSnapshotMode = .compatibleStreamStill,
        maximumSnapshotBytes: Int = ImageAttachment.defaultMaximumBytes,
        applicationLifecycle: MetaDATApplicationLifecycle? = nil,
        diagnostics: AWLDiagnosticRecorder? = nil
    ) {
        precondition(connectTimeout > .zero)
        precondition(eventBufferLimit > 0)
        self.wearables = wearables
        self.connectTimeout = connectTimeout
        self.applicationLifecycle = applicationLifecycle
        self.diagnostics = diagnostics
        self.eventSource = MetaDATDeviceEventSource(bufferLimit: eventBufferLimit)
        self.cameraSnapshotController = MetaDATCameraSnapshotController(
            timeout: snapshotTimeout,
            maximumBytes: maximumSnapshotBytes,
            snapshotMode: snapshotMode
        )
    }

    /// Filters final transcripts before they become interactions. Return the
    /// request text to forward, or nil to drop the utterance (e.g. no wake
    /// phrase, or the app's own reply echoing back). Nil gate forwards all.
    public func setTranscriptGate(_ gate: (@Sendable (String) async -> String?)?) {
        transcriptGate = gate
    }

    /// Receives glasses touch/button input once Inputs is attached. A double
    /// tap arrives as select; single tap and tap-and-hold stay with the system.
    public func setGlassesInputHandler(
        _ handler: (@Sendable (_ isSelect: Bool, _ description: String) async -> Void)?
    ) {
        glassesInputHandler = handler
    }

    /// Human-readable lifecycle notes (Speech state, restarts, Inputs) for
    /// field diagnostics. Never receives transcript text.
    public func setActivityLogger(_ logger: (@Sendable (String) -> Void)?) {
        activityLogger = logger
    }

    public nonisolated func events() -> AsyncStream<InteractionEvent> {
        eventSource.stream()
    }

    /// Opt in to post-acknowledgement foreground media activation. Disabled by
    /// default and retired with Voice Invocation ownership; never authorize
    /// background camera/Speech access via this method.
    public func setForegroundMediaActivationOnVoiceLaunch(_ enabled: Bool) {
        foregroundMediaActivationOnVoiceLaunch = enabled
        if enabled {
            observeForegroundForPendingVoiceLaunch()
        } else {
            pendingVoiceMediaLease = nil
            voicePhaseTask?.cancel()
            voicePhaseTask = nil
        }
    }

    private func observeForegroundForPendingVoiceLaunch() {
        guard foregroundMediaActivationOnVoiceLaunch,
              voiceInvocationChannel != nil,
              voicePhaseTask == nil,
              let applicationLifecycle else { return }

        let phases = applicationLifecycle.phases()
        voicePhaseTask = Task { [weak self] in
            for await phase in phases {
                guard !Task.isCancelled else { break }
                if phase == .foreground {
                    await self?.resumePendingVoiceLaunchOnForeground()
                }
            }
        }
    }

    private func resumePendingVoiceLaunchOnForeground() async {
        guard let lease = pendingVoiceMediaLease,
              voiceStartFence.owns(lease) else { return }
        pendingVoiceMediaLease = nil
        await activateMediaAfterAcknowledgedVoiceLaunch(voiceLease: lease)
    }

    private func activateMediaAfterAcknowledgedVoiceLaunch(voiceLease: UInt64) async {
        // A delayed task from a retired listener must not activate media for
        // a different listener that restarted after a disconnect/reconnect.
        guard voiceStartFence.owns(voiceLease),
              voiceInvocationChannel != nil else { return }
        // Without a host lifecycle source, foreground ownership is unknown.
        // Never interpret missing evidence as permission to start media.
        let phase = await applicationLifecycle?.currentPhase ?? .background
        if phase == .background {
            // Cold launches may deliver the acknowledgement before SwiftUI
            // reports .active. Keep one fenced handoff pending for foreground;
            // never open a media session while iOS is backgrounded.
            if foregroundMediaActivationOnVoiceLaunch,
               voiceStartFence.owns(voiceLease) {
                pendingVoiceMediaLease = voiceLease
                observeForegroundForPendingVoiceLaunch()
            }
            return
        }
        guard MetaDATVoiceMediaActivationPolicy.mayActivate(
            optedIn: foregroundMediaActivationOnVoiceLaunch,
            foreground: phase == .foreground,
            connecting: connecting,
            sessionActive: deviceSession != nil,
            stopping: stopping
        ),
        voiceStartFence.owns(voiceLease) else { return }

        do {
            // The acknowledgement event has already entered Core's event
            // stream. Do not delay it on SDK media/session startup.
            try await connect()
        } catch {
            guard foregroundMediaActivationOnVoiceLaunch,
                  voiceStartFence.owns(voiceLease),
                  voiceInvocationChannel != nil else { return }
            // Media is optional for the wake channel. Failure must not retire
            // an otherwise healthy voice-only Core/Gateway runtime.
            yieldEvent(.failed(
                nil,
                .capabilityUnavailable("Meta DAT foreground media handoff failed")
            ))
        }
    }

    /// Starts the independent, registration-gated Voice Invocation channel.
    /// This never starts DeviceSession, Speech, or the camera stream.
    /// The host must subscribe to events() before enabling the channel.
    public func startVoiceInvocationListening() async {
        guard voiceInvocationChannel == nil,
              let token = voiceStartFence.begin() else { return }
        defer { voiceStartFence.finish(token) }

        let source = eventSource
        let capabilities = liveCapabilities
        let channel = await MainActor.run {
            MetaDATVoiceInvocationChannel(
                wearables: wearables,
                diagnostics: diagnostics,
                onEvent: { [weak self] event in
                    source.yield(event)
                    if case .invocation = event {
                        Task { await self?.activateMediaAfterAcknowledgedVoiceLaunch(voiceLease: token) }
                    }
                },
                onReadiness: { ready in
                    capabilities.update(voiceInvocationReady: ready)
                }
            )
        }
        // stop() may run while the actor awaits MainActor allocation. Never
        // publish or start a channel belonging to a retired generation.
        guard voiceStartFence.owns(token) else {
            await channel.stop()
            return
        }
        voiceInvocationChannel = channel
        observeForegroundForPendingVoiceLaunch()
        await channel.start()
        // An async stop during channel.start() must not leave a ghost listener.
        if !voiceStartFence.owns(token) {
            await channel.stop()
        }
    }

    /// Explicitly retires Voice Invocation without affecting DeviceSession.
    public func stopVoiceInvocationListening() async {
        setForegroundMediaActivationOnVoiceLaunch(false)
        voiceStartFence.invalidate()
        let channel = voiceInvocationChannel
        voiceInvocationChannel = nil
        await channel?.stop()
        liveCapabilities.update(voiceInvocationReady: false)
    }

    public func connect() async throws {
        guard try MetaDATConnectAdmission.shouldStart(
            connecting: connecting,
            sessionActive: deviceSession != nil
        ) else { return }

        // Reject a cold start in the background. The subscribed phase stream
        // below also replays its latest phase, closing the gap between this
        // preflight and registration/session startup.
        if let applicationLifecycle {
            guard await applicationLifecycle.currentPhase == .foreground else {
                throw AWLError.device("Meta DAT media cannot start while the app is backgrounded")
            }
        }

        // The phase check above suspends this actor. Another caller may have
        // started/finished a media connect while we awaited it, so repeat
        // admission immediately before taking ownership of a new generation.
        guard try MetaDATConnectAdmission.shouldStart(
            connecting: connecting,
            sessionActive: deviceSession != nil
        ) else { return }

        liveCapabilities.update(
            sessionReady: false,
            speechReady: false,
            cameraReady: false
        )
        // Media's own phase observer now owns the one-slot lifecycle stream.
        // Restore the independent voice observer when that media retires.
        voicePhaseTask?.cancel()
        voicePhaseTask = nil
        pendingVoiceMediaLease = nil
        stopping = false
        connecting = true
        let generation = generationFence.begin()
        diagnostics?.record(.init(kind: .metaConnectStarted, generation: generation))
        defer {
            if generationFence.owns(generation) {
                connecting = false
            }
        }

        if let applicationLifecycle {
            let phases = applicationLifecycle.phases()
            applicationPhaseTask = Task { [weak self] in
                for await phase in phases {
                    guard !Task.isCancelled else { break }
                    await self?.handleApplicationPhase(phase, generation: generation)
                }
            }
        }

        guard case .registered = wearables.registrationState else {
            tearDownSession(expectedGeneration: generation)
            throw AWLError.device("Meta DAT application is not registered")
        }

        let registrationWearables = wearables
        registrationTask = Task { [weak self, registrationWearables] in
            for await state in registrationWearables.registrationStateStream() {
                guard !Task.isCancelled else { break }
                guard case .registered = state else {
                    await self?.handleRegistrationLoss(generation: generation)
                    break
                }
            }
        }

        let devices = wearables.devices.compactMap {
            self.wearables.deviceForIdentifier($0)
        }
        let selectionCandidates = devices.map {
            MetaDATDeviceSelectionCandidate(
                identifier: $0.identifier,
                rank: Self.deviceRank($0)
            )
        }
        guard let selectedIdentifier = MetaDATDeviceSelectionPolicy.selectedIdentifier(
            from: selectionCandidates
        ),
        let selectedDevice = devices.first(where: { $0.identifier == selectedIdentifier }) else {
            tearDownSession(expectedGeneration: generation)
            throw AWLError.device("Meta DAT has no paired device eligible for session selection")
        }
        guard selectedDevice.compatibility() == .compatible else {
            tearDownSession(expectedGeneration: generation)
            throw AWLError.device("Selected Meta DAT device is not SDK-compatible")
        }

        selectedDeviceLinkLossGate = MetaDATSelectedDeviceLinkLossGate(
            initiallyConnected: selectedDevice.linkState == .connected
        )

        selectedDeviceListenerTask = Task { [weak self] in
            await self?.monitorSelectedDeviceSignals(
                selectedDevice,
                generation: generation
            )
        }
        deviceMonitorTask = Task { [weak self] in
            await self?.monitorSelectedDevice(
                selectedIdentifier,
                generation: generation
            )
        }

        let selector = SpecificDeviceSelector(device: selectedIdentifier)
        let session: DeviceSession
        do {
            session = try wearables.createSession(deviceSelector: selector)
        } catch {
            tearDownSession(expectedGeneration: generation)
            throw error
        }

        guard generationFence.owns(generation), !stopping else {
            throw AWLError.device("Meta DAT session setup was superseded")
        }
        deviceSession = session

        // Obtain the streams before start() so initial state/error transitions
        // cannot be missed. Meta's current samples use the same ordering.
        let stateStream = session.stateStream()
        let errorStream = session.errorStream()

        errorTask = Task { [weak self] in
            for await error in errorStream {
                guard !Task.isCancelled else { break }
                await self?.emitDeviceError(
                    error,
                    generation: generation
                )
            }
        }

        do {
            try session.start()

            try await waitUntilStarted(
                stateStream,
                timeout: connectTimeout
            )

            selectedDeviceLinkLossGate.markSessionStarted()
            liveCapabilities.update(sessionReady: true)

            do {
                try await startSpeech(
                    on: session,
                    generation: generation
                )
                liveCapabilities.update(speechReady: true)
            } catch {
                guard MetaDATSpeechSetupPolicy.mayContinueWithoutSpeech(error) else {
                    // Session-generation retirement and unexpected failures
                    // must never be misclassified as optional availability.
                    throw error
                }
                // DAT Speech is optional. A missing microphone grant or
                // unsupported device does not invalidate independently
                // permissioned explicit camera snapshots.
                liveCapabilities.update(speechReady: false)
            }

            // Camera is attached lazily for explicit snapshots, but permission
            // is part of whether that production surface is currently usable.
            // A permission-query failure must fail closed without discarding an
            // otherwise healthy Speech/session connection.
            let cameraReady: Bool
            do {
                cameraReady = try await wearables.checkPermissionStatus(.camera) == .granted
            } catch {
                cameraReady = false
            }
            liveCapabilities.update(cameraReady: cameraReady)

            // Do not create a second stateStream() after consuming .started.
            // Continue the same stream in one observer so SDK stream semantics cannot
            // create a gap between startup and steady-state monitoring.
            guard generationFence.owns(generation), !stopping else {
                throw AWLError.device("Meta DAT session setup was superseded")
            }
            diagnostics?.record(.init(kind: .metaSessionReady, generation: generation))
            attachInputs(to: session, generation: generation)

            stateTask = Task { [weak self] in
                for await state in stateStream {
                    guard !Task.isCancelled else { break }
                    await self?.observeSessionState(state, generation: generation)

                    if state == .stopped {
                        await self?.handleUnexpectedStop(generation: generation)
                        break
                    }
                }
            }
        } catch {
            // A stale connect continuation must never tear down a newer retry.
            tearDownSession(expectedGeneration: generation)
            throw error
        }
    }

    public func captureSnapshot(
        interactionID: InteractionID
    ) async throws -> ImageAttachment {
        guard !stopping,
              let session = deviceSession else {
            throw AWLError.device("Meta DAT device session is not connected")
        }

        let generation = generationFence.current
        let cameraGranted: Bool
        do {
            cameraGranted = try await wearables.checkPermissionStatus(.camera) == .granted
        } catch {
            // A stale permission query must not overwrite the readiness of
            // a newer session created while this snapshot was suspended.
            if generationFence.owns(generation),
               !stopping,
               deviceSession === session {
                liveCapabilities.update(cameraReady: false)
            }
            throw error
        }

        guard generationFence.owns(generation),
              !stopping,
              deviceSession === session else {
            throw CancellationError()
        }
        guard cameraGranted else {
            liveCapabilities.update(cameraReady: false)
            throw AWLError.capabilityUnavailable(
                "Meta DAT camera permission is not granted"
            )
        }
        liveCapabilities.update(cameraReady: true)

        diagnostics?.record(.init(
            kind: .metaSnapshotRequested,
            interactionID: interactionID,
            generation: generation
        ))

        let image: ImageAttachment
        do {
            image = try await cameraSnapshotController.capture(from: session)
        } catch {
            diagnostics?.record(.init(
                kind: .metaSnapshotFailed,
                interactionID: interactionID,
                generation: generation
            ))
            throw error
        }

        guard generationFence.owns(generation),
              !stopping,
              deviceSession === session else {
            throw CancellationError()
        }

        diagnostics?.record(.init(
            kind: .metaSnapshotCompleted,
            interactionID: interactionID,
            generation: generation
        ))
        return image
    }

    private func startSpeech(
        on session: DeviceSession,
        generation: UInt64
    ) async throws {
        guard generationFence.owns(generation), !stopping else {
            throw AWLError.device("Meta DAT Speech setup was superseded")
        }

        let microphoneStatus = try await wearables.checkPermissionStatus(.microphone)
        // Permission checks suspend the actor; disconnect/reconnect may have
        // retired the owning session before this continuation resumes.
        guard generationFence.owns(generation),
              !stopping,
              deviceSession === session else {
            throw CancellationError()
        }
        guard microphoneStatus == .granted else {
            throw AWLError.capabilityUnavailable(
                "Meta DAT microphone permission is not granted"
            )
        }

        guard let speech = try session.addSpeech() else {
            throw AWLError.capabilityUnavailable(
                "Meta DAT Speech is unavailable for the selected device"
            )
        }

        await transcriptDeduplicator.reset()

        // Do not create/start a Speech listener for an already retired
        // DeviceSession, or let a stale setup task overwrite the new session.
        guard generationFence.owns(generation),
              !stopping,
              deviceSession === session else {
            throw CancellationError()
        }

        let transcripts = speechTranscriptStream.stream(from: speech)
        speechTask = Task { [weak self] in
            for await transcript in transcripts {
                guard !Task.isCancelled else { break }
                await self?.handleSpeechTranscript(
                    transcript,
                    generation: generation
                )
            }
        }

        speechErrorToken = speech.errorPublisher.listen { [weak self] error in
            Task {
                await self?.handleSpeechError(
                    error,
                    generation: generation
                )
            }
        }

        speechStateToken = speech.statePublisher.listen { [weak self] state in
            Task { await self?.handleSpeechState(state, generation: generation) }
        }
        // The recognizer's locale (never transcript text) for field logs.
        speechLocaleToken = speech.localePublisher.listen { [weak self] locale in
            Task { await self?.logSpeechLocale(locale, generation: generation) }
        }
        speechRestartAttempts = 0
        speechPaused = false
        self.speech = speech
        speech.start()
        markSpeechRestarted()
        markSpeechFreshStart()
        startSpeechStallWatchdog(generation: generation)

        guard generationFence.owns(generation), !stopping else {
            throw AWLError.device("Meta DAT Speech setup was superseded")
        }
    }

    private func handleSpeechTranscript(
        _ transcript: MetaDATTranscript,
        generation: UInt64
    ) async {
        guard !stopping, generationFence.owns(generation) else { return }

        // Every event counts for the stall watchdog, including empty ones and
        // partials, and is recorded before deduplication or gating.
        let now = ContinuousClock.now
        lastTranscriptEventAt = now
        speechEventCount += 1
        if !transcript.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lastNonEmptyTranscriptAt = now
            speechNonEmptyCount += 1
            emptyOnlyRestartsInARow = 0
        }

        let accepted = await transcriptDeduplicator.accept(
            .init(text: transcript.text, isFinal: transcript.isFinal)
        )
        guard accepted else { return }

        var transcript = transcript
        if transcript.isFinal, let transcriptGate {
            guard let request = await transcriptGate(transcript.text),
                  !stopping, generationFence.owns(generation) else { return }
            transcript = MetaDATTranscript(text: request, isFinal: true, confidence: transcript.confidence)
        } else if !transcript.isFinal, transcriptGate != nil {
            // Partials are not shown to the agent; only gated finals count.
            return
        }

        let interactionID = InteractionID()
        guard let event = finalTranscriptFilter.event(
            for: .init(text: transcript.text, isFinal: transcript.isFinal),
            interactionID: interactionID
        ) else {
            return
        }
        diagnostics?.record(.init(
            kind: .metaTranscriptAccepted,
            interactionID: interactionID,
            generation: generation
        ))
        yieldEvent(event)
    }

    private func markSpeechFreshStart() {
        speechFreshStartAt = ContinuousClock.now
        emptyOnlyRestartsInARow = 0
    }

    private func markSpeechRestarted() {
        let now = ContinuousClock.now
        lastTranscriptEventAt = now
        lastNonEmptyTranscriptAt = now
    }

    private func startSpeechStallWatchdog(generation: UInt64) {
        speechStallTask?.cancel()
        speechStallTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: MetaDATSpeechStallPolicy.checkInterval)
                guard let self, !Task.isCancelled else { return }
                let keepGoing = await self.checkSpeechStall(generation: generation)
                if !keepGoing { return }
            }
        }
    }

    /// Returns false once the generation is retired.
    private func checkSpeechStall(generation: UInt64) async -> Bool {
        guard !stopping, generationFence.owns(generation) else { return false }
        guard let speech else { return true }
        let now = ContinuousClock.now
        // Counts only (never text): tells "silent room" from "deaf Speech".
        speechStatsChecks += 1
        if speechStatsChecks % 5 == 0 {
            activityLogger?("speech events \(speechEventCount) (non-empty \(speechNonEmptyCount)) in last 10 s, state \(speech.state)")
            speechEventCount = 0
            speechNonEmptyCount = 0
        }
        func seconds(_ instant: ContinuousClock.Instant?) -> TimeInterval? {
            guard let instant else { return nil }
            let duration = now - instant
            return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        }
        let action = MetaDATSpeechStallPolicy.action(
            sinceAnyEvent: seconds(lastTranscriptEventAt),
            sinceNonEmpty: seconds(lastNonEmptyTranscriptAt),
            speechStarted: speech.state == .started,
            sessionStarted: sessionIsStarted,
            pausedByHost: speechPaused || speechStallRestarting,
            emptyOnlyLimit: MetaDATSpeechStallPolicy.emptyOnlyLimit(
                consecutiveEmptyRestarts: emptyOnlyRestartsInARow,
                sinceFreshStart: seconds(speechFreshStartAt)
            )
        )
        guard case let .restart(reason) = action else { return true }
        speechStallRestarts += 1
        if reason == .emptyOnly { emptyOnlyRestartsInARow += 1 }
        activityLogger?("speech stall restart \(speechStallRestarts) (\(reason.rawValue))")
        speechStallRestarting = true
        speech.stop()
        try? await Task.sleep(for: MetaDATSpeechStallPolicy.restartGap)
        speechStallRestarting = false
        guard !stopping, !speechPaused, generationFence.owns(generation), self.speech === speech else {
            return generationFence.owns(generation)
        }
        markSpeechRestarted()
        speech.start()
        return true
    }

    /// The session came back from `.paused`: Speech that stopped meanwhile
    /// is not restarted by its own stop handler.
    private func handleSessionResumed(generation: UInt64) {
        guard !stopping, generationFence.owns(generation), let speech else { return }
        guard MetaDATSpeechStallPolicy.shouldRestartAfterSessionResumes(
            speechStopped: speech.state == .stopped,
            pausedByHost: speechPaused
        ) else { return }
        activityLogger?("speech restarted after session resumed")
        speechRestartAttempts = 0
        markSpeechRestarted()
        markSpeechFreshStart()
        speech.start()
    }

    private func logSpeechLocale(_ locale: String, generation: UInt64) {
        guard !stopping, generationFence.owns(generation) else { return }
        activityLogger?("speech locale \(locale)")
    }

    /// Stops DAT Speech but keeps the DeviceSession and the attached Speech
    /// (glasses taken off or folded). Idempotent.
    public func pauseSpeech() {
        guard !stopping, let speech, !speechPaused else { return }
        speechPaused = true
        activityLogger?("speech paused")
        speech.stop()
    }

    /// Restarts the attached Speech after `pauseSpeech()`. Idempotent; a no-op
    /// when the session (and its Speech) is gone, which recovery handles.
    private func observeSessionState(_ state: DeviceSessionState, generation: UInt64) {
        guard generationFence.owns(generation) else { return }
        let wasStarted = sessionIsStarted
        sessionIsStarted = state == .started
        if state == .paused { activityLogger?("session paused") }
        if sessionIsStarted, !wasStarted {
            activityLogger?("session started")
            handleSessionResumed(generation: generation)
        }
    }

    public func resumeSpeech() {
        guard !stopping, let speech, speechPaused else { return }
        speechPaused = false
        speechRestartAttempts = 0
        activityLogger?("speech resumed")
        markSpeechRestarted()
        markSpeechFreshStart()
        speech.start()
    }

    public var isSpeechPaused: Bool { speechPaused }

    private func handleSpeechState(_ state: SpeechState, generation: UInt64) async {
        guard !stopping, generationFence.owns(generation), let speech else { return }
        activityLogger?("speech \(state)")
        let observed: MetaDATSpeechRestartPolicy.ObservedState
        switch state {
        case .started: observed = .started
        case .stopped: observed = .stopped
        default: observed = .transitioning
        }
        switch MetaDATSpeechRestartPolicy.action(
            for: observed, attempts: speechRestartAttempts,
            // A stall restart's own stop, or a paused session, is not an
            // unrequested stop.
            paused: speechPaused || speechStallRestarting || !sessionIsStarted
        ) {
        case .resetAttempts:
            speechRestartAttempts = 0
        case let .restart(attempt):
            speechRestartAttempts = attempt
            try? await Task.sleep(for: MetaDATSpeechRestartPolicy.delay)
            guard !stopping, !speechPaused, generationFence.owns(generation), self.speech === speech else { return }
            activityLogger?("speech restart \(attempt)")
            speech.start()
        case .giveUp:
            activityLogger?("speech restart limit reached")
        case .none:
            break
        }
    }

    private func attachInputs(to session: DeviceSession, generation: UInt64) {
        guard inputs == nil else { return }
        let attached: Inputs?
        do {
            // Ask for the temple and both buttons (narrow subscriptions went
            // silent in BirdSpotter) and keep Back so a swipe cannot end the
            // session.
            attached = try session.addInputs(configuration: InputsConfiguration(
                sources: [.captouch, .captureButton, .actionButton],
                consumeBack: true
            ))
        } catch {
            activityLogger?("inputs unavailable: \(error)")
            return
        }
        guard let attached else {
            activityLogger?("inputs not attached")
            return
        }
        inputs = attached
        activityLogger?("inputs attached")
        let events = attached.events
        inputsTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { break }
                await self?.handleGlassesInput(event, generation: generation)
            }
        }
    }

    private func handleGlassesInput(_ event: InputEvent, generation: UInt64) async {
        guard !stopping, generationFence.owns(generation) else { return }
        let isSelect: Bool
        if case .select = event { isSelect = true } else { isSelect = false }
        activityLogger?("input \(event)")
        await glassesInputHandler?(isSelect, "\(event)")
    }

    private func handleSpeechError(
        _ error: any Error,
        generation: UInt64
    ) {
        guard !stopping, generationFence.owns(generation), speech != nil else { return }

        // Speech is optional. A vendor transcript channel failure should only
        // retire Speech; a nil-ID .device error would retire the entire Core
        // runtime generation and unnecessarily drop healthy camera/agent work.
        liveCapabilities.update(speechReady: false)
        speechTask?.cancel()
        speechTask = nil
        speech?.stop()
        speech = nil
        if let speechErrorToken {
            Task { await speechErrorToken.cancel() }
        }
        speechErrorToken = nil
        yieldEvent(MetaDATSpeechFailurePolicy.event(for: error))
    }

    private func monitorSelectedDeviceSignals(
        _ device: Device,
        generation: UInt64
    ) async {
        let linkToken = device.addLinkStateListener { [weak self] state in
            Task {
                await self?.handleSelectedDeviceLinkState(
                    isConnected: state == .connected,
                    description: "\(state)",
                    generation: generation
                )
            }
        }
        let compatibilityToken = device.addCompatibilityListener { [weak self] compatibility in
            guard compatibility != .compatible else { return }
            Task { await self?.handleSelectedDeviceUnavailable(
                "Selected Meta DAT device became incompatible: \(compatibility)",
                generation: generation
            ) }
        }

        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                break
            }
        }

        // This task is the sole owner of listener-token cancellation.
        await linkToken.cancel()
        await compatibilityToken.cancel()
    }

    private func monitorSelectedDevice(
        _ selectedIdentifier: DeviceIdentifier,
        generation: UInt64
    ) async {
        for await identifiers in wearables.devicesStream() {
            guard !Task.isCancelled else { break }
            guard identifiers.contains(selectedIdentifier),
                  let device = wearables.deviceForIdentifier(selectedIdentifier) else {
                handleSelectedDeviceUnavailable(
                    "Selected Meta DAT device is no longer paired/available",
                    generation: generation
                )
                return
            }

            let compatibility = device.compatibility()
            guard compatibility == .compatible else {
                handleSelectedDeviceUnavailable(
                    "Selected Meta DAT device became incompatible: \(compatibility)",
                    generation: generation
                )
                return
            }
        }
    }

    private func handleSelectedDeviceLinkState(
        isConnected: Bool,
        description: String,
        generation: UInt64
    ) {
        guard !stopping, generationFence.owns(generation) else { return }

        guard selectedDeviceLinkLossGate.observe(isConnected: isConnected) else {
            return
        }

        handleSelectedDeviceUnavailable(
            "Selected Meta DAT device link became unavailable: \(description)",
            generation: generation
        )
    }

    private func handleSelectedDeviceUnavailable(
        _ message: String,
        generation: UInt64
    ) {
        guard !stopping,
              generationFence.owns(generation),
              deviceSession != nil else {
            return
        }
        emitMediaFailure(message)
        tearDownSession(expectedGeneration: generation)
    }

    private nonisolated static func deviceRank(_ device: Device) -> Int {
        if device.linkState == .connected && device.donState == .donned { return 0 }
        if device.linkState == .connected { return 1 }
        if device.compatibility() == .compatible { return 2 }
        return 3
    }

    private func waitUntilStarted(
        _ states: AsyncStream<DeviceSessionState>,
        timeout: Duration
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await state in states {
                    try Task.checkCancellation()
                    if state == .started { return }
                    if state == .stopped {
                        throw AWLError.device(
                            "Meta DAT session stopped before reaching started"
                        )
                    }
                }
                throw AWLError.device(
                    "Meta DAT session state stream ended before reaching started"
                )
            }

            group.addTask {
                try await Task.sleep(for: timeout)
                throw AWLError.device(
                    "Meta DAT session did not reach started before timeout"
                )
            }

            _ = try await group.next()
            group.cancelAll()
        }
    }

    public func disconnect() async {
        stopping = true
        tearDownSession()
    }

    private func handleApplicationPhase(
        _ phase: MetaDATApplicationPhase,
        generation: UInt64
    ) {
        guard generationFence.owns(generation), !stopping else { return }
        guard phase == .background else { return }

        // A backgrounded camera/Speech session cannot be reused safely. The
        // generation fence rejects late photo bytes/transcripts; foreground
        // recovery requires a *new explicit* connect, never request replay.
        liveCapabilities.update(
            sessionReady: false,
            speechReady: false,
            cameraReady: false
        )
        diagnostics?.record(.init(kind: .metaBackgroundRetired, generation: generation))
        emitMediaFailure("Meta DAT media retired on app background")
        tearDownSession(expectedGeneration: generation)
    }

    private func handleUnexpectedStop(generation: UInt64) {
        guard !stopping, generationFence.owns(generation) else { return }
        emitMediaFailure("Meta DAT device session stopped")
        tearDownSession(expectedGeneration: generation)
    }

    private func handleRegistrationLoss(generation: UInt64) {
        guard !stopping, generationFence.owns(generation) else { return }

        // Registration ownership begins before DeviceSession creation. Do not
        // require deviceSession != nil here: revocation during startup must
        // invalidate the whole connect generation.
        emitMediaFailure("Meta DAT registration became unavailable")
        tearDownSession(expectedGeneration: generation)
    }

    private func emitDeviceError(_ error: any Error, generation: UInt64) {
        guard !stopping, generationFence.owns(generation) else { return }
        emitMediaFailure(MetaDATVendorFailurePolicy.message(
            for: error,
            surface: .session
        ))
    }

    private func yieldEvent(_ event: InteractionEvent) {
        eventSource.yield(event)
    }

    private func emitMediaFailure(_ message: String) {
        yieldEvent(MetaDATMediaFailurePolicy.event(
            message,
            preserveIndependentVoice:
                foregroundMediaActivationOnVoiceLaunch && voiceInvocationChannel != nil
        ))
    }

    private func tearDownSession(expectedGeneration: UInt64? = nil) {
        let retiredGeneration = generationFence.current
        guard generationFence.retire(ifOwned: expectedGeneration) else {
            return
        }
        diagnostics?.record(.init(kind: .metaMediaRetired, generation: retiredGeneration))

        liveCapabilities.update(
            sessionReady: false,
            speechReady: false,
            cameraReady: false
        )
        cameraSnapshotController.invalidate()
        applicationPhaseTask?.cancel()
        applicationPhaseTask = nil
        stateTask?.cancel()
        errorTask?.cancel()
        registrationTask?.cancel()
        deviceMonitorTask?.cancel()
        selectedDeviceListenerTask?.cancel()
        speechTask?.cancel()
        stateTask = nil
        errorTask = nil
        registrationTask = nil
        deviceMonitorTask = nil
        selectedDeviceListenerTask = nil
        speechTask = nil

        // Session teardown is the terminal Speech detach boundary. Avoid
        // removeSpeech() here because the transcript helper owns its listener
        // token and retires it asynchronously when the consumer task ends.
        // Generation fencing prevents any late callback from escaping while
        // DeviceSession.stop() releases the attached Speech surface.
        speech?.stop()
        speech = nil

        if let speechErrorToken {
            Task { await speechErrorToken.cancel() }
        }
        self.speechErrorToken = nil
        if let speechStateToken {
            Task { await speechStateToken.cancel() }
        }
        self.speechStateToken = nil
        if let speechLocaleToken {
            Task { await speechLocaleToken.cancel() }
        }
        self.speechLocaleToken = nil
        speechPaused = false
        speechStallTask?.cancel()
        speechStallTask = nil
        speechStallRestarting = false
        sessionIsStarted = true
        inputsTask?.cancel()
        inputsTask = nil
        inputs = nil

        deviceSession?.stop()
        deviceSession = nil
        selectedDeviceLinkLossGate = MetaDATSelectedDeviceLinkLossGate()
        connecting = false
        stopping = false
        observeForegroundForPendingVoiceLaunch()
    }
}
