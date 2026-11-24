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

typealias MetaDATDeviceEventSource = BoundedDeviceEventSource

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

    /// Distinguishes SDK state, healthy callback delivery, and observation of
    /// recognition activity. No text, audio, device ID or credentials exposed.
    public var speechHealth: MetaDATSpeechHealth {
        let sessionStarted = !stopping && deviceSession?.state == .started
        let phase: MetaDATSpeechHealth.Phase
        switch speech?.state {
        case .starting?: phase = .starting
        case .started?: phase = .started
        case .stopping?: phase = .stopping
        case .stopped?: phase = .stopped
        case nil: phase = .detached
        }
        return speechDelivery?.health(sessionStarted: sessionStarted, phase: phase)
            ?? MetaDATSpeechHealth(sessionStarted: sessionStarted, phase: phase, deliveryActive: false)
    }

    private func refreshMediaReadiness() {
        let health = speechHealth
        let ready = health.isSDKReady && !speechPaused && !speechStallRestarting
            && !stallStopUnconfirmed && noEventRecoveryAttempts <= MetaDATSpeechStallPolicy.noEventRecoveryLimit
        liveCapabilities.update(sessionReady: health.sessionStarted, speechReady: ready)
        notifySpeechReadiness(ready)
    }

    private func notifySpeechReadiness(_ ready: Bool) {
        guard lastReportedSpeechReady != ready else { return }
        lastReportedSpeechReady = ready
        speechReadinessObserver?()
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
    private var speechRunStartedAt: ContinuousClock.Instant?
    private var lastObservedCallbackAt: ContinuousClock.Instant?
    private var lastObservedNonEmptyCallbackAt: ContinuousClock.Instant?
    private var speechStatsChecks = 0
    private var speechStallTask: Task<Void, Never>?
    private var speechReviveTask: Task<Void, Never>?
    private let defaultSnapshotMode: MetaDATSnapshotMode
    private var speechStallRestarting = false
    private var noEventRecoveryAttempts = 0
    private var stallStopUnconfirmed = false
    private var speechStallRestarts = 0
    /// Recent unrequested Speech stops (monotonic seconds) for the backoff.
    private var unrequestedSpeechStops: [TimeInterval] = []
    /// When a stall restart last called `stop()` (monotonic seconds).
    private var lastStallStopAt: TimeInterval?
    /// Empty-only restarts since the last non-empty transcript (backoff).
    private var emptyOnlyRestartsInARow = 0
    /// Last fresh Speech start (connect, resume, session resume).
    private var speechFreshStartAt: ContinuousClock.Instant?
    private var sessionIsStarted = false
    private var inputs: Inputs?
    private var inputsTask: Task<Void, Never>?
    private var transcriptGate: (@Sendable (String) async -> String?)?
    private var glassesInputHandler: (@Sendable (_ isSelect: Bool, _ description: String) async -> Void)?
    private var activityLogger: (@Sendable (String) -> Void)?
    private var sessionErrorObserver: (@Sendable (MetaDATSessionErrorKind) -> Void)?
    private var sessionPauseObserver: (@Sendable (_ paused: Bool) -> Void)?
    private var speechReadinessObserver: (@Sendable () -> Void)?
    private var lastReportedSpeechReady = false
    /// A `.paused` was reported to the pause observer and not yet resolved.
    private var sessionPauseReported = false
    /// MODERATE heat: optional work is reduced (speech stats less often).
    private var reducedWork = false
    private let speechTranscriptStream = MetaDATSpeechTranscriptStream()
    private var speechDelivery: MetaDATSpeechTranscriptDelivery?
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
        self.defaultSnapshotMode = snapshotMode
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

    /// Receives every DeviceSessionError from the live session's error
    /// stream, by case name only, before any failure event is emitted.
    public func setSessionErrorObserver(_ observer: (@Sendable (MetaDATSessionErrorKind) -> Void)?) {
        sessionErrorObserver = observer
    }

    /// Receives `true` when the device pauses the live session (a single
    /// temple tap; the app never gets the tap itself and cannot resume) and
    /// `false` when that session is started again by a second tap. A stop
    /// is not reported here (it ends the session as a media failure).
    public func setSessionPauseObserver(_ observer: (@Sendable (_ paused: Bool) -> Void)?) {
        sessionPauseObserver = observer
    }

    /// Notify the host to resample current capabilities, not a stale bool.
    public func setSpeechReadinessObserver(_ observer: (@Sendable () -> Void)?) {
        speechReadinessObserver = observer
    }

    /// Meta thermal guidance for MODERATE: reduce optional work. Here that
    /// stretches the Speech statistics log line; Speech itself keeps running.
    public func setReducedWork(_ reduced: Bool) {
        guard reduced != reducedWork else { return }
        reducedWork = reduced
        activityLogger?(reduced ? "reduced work: speech stats every \(MetaDATSpeechStallPolicy.statsSeconds(reduced: true)) s" : "reduced work off")
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
        } catch DeviceSessionError.notRegistered {
            // Registration may be revoked between preflight and creation in DAT 1.1.
            tearDownSession(expectedGeneration: generation)
            throw AWLError.device("Meta DAT application is not registered")
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

            guard generationFence.owns(generation), !stopping,
                  deviceSession === session else { throw CancellationError() }
            selectedDeviceLinkLossGate.markSessionStarted()
            sessionIsStarted = session.state == .started
            refreshMediaReadiness()

            do {
                try await startSpeech(
                    on: session,
                    generation: generation
                )
                guard generationFence.owns(generation), !stopping,
                      deviceSession === session else { throw CancellationError() }
                refreshMediaReadiness()
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
            guard generationFence.owns(generation), !stopping,
                  deviceSession === session else { throw CancellationError() }
            liveCapabilities.update(cameraReady: cameraReady)
            refreshMediaReadiness()

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
        try await captureSnapshot(interactionID: interactionID, mode: defaultSnapshotMode).image
    }

    /// Stage timings of the latest capture attempt (also a failed one).
    public var lastSnapshotTimings: MetaDATSnapshotTimings? {
        cameraSnapshotController.lastAttemptTimings
    }

    /// One explicit still in `mode`, with stage timings. Afterwards Speech
    /// is revived if the photo put it down (BirdSpotter: "a photograph is
    /// what puts it down"); the audio session is never touched here.
    public func captureSnapshot(
        interactionID: InteractionID,
        mode: MetaDATSnapshotMode
    ) async throws -> MetaDATSnapshotResult {
        guard !stopping,
              let session = deviceSession else {
            throw AWLError.device("Meta DAT device session is not connected")
        }
        guard session.state == .started else {
            throw AWLError.capabilityUnavailable("Meta DAT media session is not started")
        }
        let generation = generationFence.current
        defer {
            if generationFence.owns(generation), deviceSession === session, session.state == .started {
                reviveSpeechAfterPhoto(generation: generation)
            }
        }
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
        guard session.state == .started else {
            throw AWLError.capabilityUnavailable("Meta DAT media session is not started")
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

        let result: MetaDATSnapshotResult
        do {
            result = try await cameraSnapshotController.capture(from: session, mode: mode)
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
              deviceSession === session, session.state == .started else {
            throw CancellationError()
        }

        diagnostics?.record(.init(
            kind: .metaSnapshotCompleted,
            interactionID: interactionID,
            generation: generation
        ))
        return result
    }

    /// Restarts Speech that a photo stopped: up to `limit` checks at the
    /// BirdSpotter cadence (750 ms), starting only while it is still stopped,
    /// so it never races the unrequested-stop handler into a double start.
    private func reviveSpeechAfterPhoto(generation: UInt64) {
        speechReviveTask?.cancel()
        speechReviveTask = Task { [weak self] in
            for attempt in 1...MetaDATSpeechRestartPolicy.limit {
                try? await Task.sleep(for: MetaDATSpeechRestartPolicy.delay)
                guard !Task.isCancelled, let self else { return }
                guard await self.reviveSpeechIfStopped(attempt: attempt, generation: generation) else { return }
            }
            await self?.logActivity("speech still stopped after photo (\(MetaDATSpeechRestartPolicy.limit) tries)")
        }
    }

    /// Returns true when another check is needed.
    private func reviveSpeechIfStopped(attempt: Int, generation: UInt64) -> Bool {
        guard !stopping, !speechPaused, !speechStallRestarting, deviceSession?.state == .started,
              generationFence.owns(generation), let speech else { return false }
        switch Self.observed(speech.state) {
        case .started:
            if attempt == 1 { activityLogger?("speech running after photo") }
            return false
        case .transitioning:
            return true
        case .stopped:
            activityLogger?("speech revived after photo (attempt \(attempt))")
            markSpeechRestarted()
            speech.start()
            refreshMediaReadiness()
            return true
        }
    }

    private func logActivity(_ line: String) {
        activityLogger?(line)
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

        // Per-attachment dedup state: a retired consumer cannot mutate
        // the replacement attachment's cache across an await.
        let deduplicator = MetaDATFinalTranscriptDeduplicator()
        let delivery = speechTranscriptStream.subscribe(from: speech) { [weak self] overflowed in
            Task {
                await self?.handleSpeechError(
                    MetaDATSpeechDeliveryError.finalTranscriptOverflow,
                    generation: generation,
                    delivery: overflowed
                )
            }
        }
        speechDelivery = delivery
        let transcripts = delivery.events()
        speechTask = Task { [weak self] in
            defer { delivery.cancel() }
            for await event in transcripts {
                guard !Task.isCancelled else { break }
                switch event {
                case let .transcript(transcript, receivedAt):
                    await self?.handleSpeechTranscript(
                        transcript,
                        receivedAt: receivedAt,
                        generation: generation,
                        delivery: delivery,
                        deduplicator: deduplicator
                    )
                case let .failed(error):
                    await self?.handleSpeechError(error, generation: generation, delivery: delivery)
                    return
                }
            }
        }

        speechErrorToken = speech.errorPublisher.listen { [weak self, weak delivery] error in
            guard let delivery else { return }
            Task {
                await self?.handleSpeechError(
                    error,
                    generation: generation,
                    delivery: delivery
                )
            }
        }

        speechStateToken = speech.statePublisher.listen { [weak self, weak delivery] state in
            guard let delivery else { return }
            Task { await self?.handleSpeechState(state, generation: generation, delivery: delivery) }
        }
        speechLocaleToken = speech.localePublisher.listen { [weak self, weak delivery] locale in
            guard let delivery else { return }
            Task { await self?.logSpeechLocale(locale, generation: generation, delivery: delivery) }
        }
        speechRestartAttempts = 0
        speechPaused = false
        self.speech = speech
        markSpeechRestarted()
        markSpeechFreshStart()
        speech.start()
        refreshMediaReadiness()
        startSpeechStallWatchdog(generation: generation)

        guard generationFence.owns(generation), !stopping else {
            throw AWLError.device("Meta DAT Speech setup was superseded")
        }
    }

    private func handleSpeechTranscript(
        _ transcript: MetaDATTranscript,
        receivedAt: ContinuousClock.Instant,
        generation: UInt64,
        delivery: MetaDATSpeechTranscriptDelivery,
        deduplicator: MetaDATFinalTranscriptDeduplicator
    ) async {
        guard !Task.isCancelled, !stopping, generationFence.owns(generation),
              speechDelivery === delivery, speech != nil, !speechPaused, !speechStallRestarting,
                  deviceSession?.state == .started,
                  speechRunStartedAt.map({ receivedAt >= $0 }) ?? false else { return }

        let accepted = await deduplicator.accept(
            .init(text: transcript.text, isFinal: transcript.isFinal),
            now: receivedAt
        )
        guard accepted, !Task.isCancelled, !stopping,
              generationFence.owns(generation), speechDelivery === delivery,
              speech != nil, !speechPaused, !speechStallRestarting,
                  deviceSession?.state == .started,
                  speechRunStartedAt.map({ receivedAt >= $0 }) ?? false else { return }

        var transcript = transcript
        if transcript.isFinal, let transcriptGate {
            guard let request = await transcriptGate(transcript.text),
                  !Task.isCancelled, !stopping,
                  generationFence.owns(generation), speechDelivery === delivery,
                  speech != nil, !speechPaused, !speechStallRestarting,
                  deviceSession?.state == .started,
                  speechRunStartedAt.map({ receivedAt >= $0 }) ?? false else { return }
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
        guard delivery.commitIfHealthy({ yieldEvent(event) }) else { return }
        diagnostics?.record(.init(
            kind: .metaTranscriptAccepted,
            interactionID: interactionID,
            generation: generation
        ))
    }

    private func markSpeechFreshStart() {
        speechFreshStartAt = ContinuousClock.now
        noEventRecoveryAttempts = 0
        stallStopUnconfirmed = false
        emptyOnlyRestartsInARow = 0
        // A fresh start (re-wear, unfold, resume) is a new situation.
        unrequestedSpeechStops = []
    }

    private static func monotonicSeconds() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    private func markSpeechRestarted() {
        speechRunStartedAt = ContinuousClock.now
        lastObservedCallbackAt = nil
        lastObservedNonEmptyCallbackAt = nil
        speechDelivery?.resetCallbackEvidence()
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
        guard let speech, let delivery = speechDelivery else { return false }
        let now = ContinuousClock.now
        let health = speechHealth
        // Only actual SDK ingress can re-arm the budget, never dequeue time.
        if let callback = health.lastCallbackAt, callback != lastObservedCallbackAt,
           speechRunStartedAt.map({ callback >= $0 }) ?? false {
            lastObservedCallbackAt = callback
            noEventRecoveryAttempts = 0
            stallStopUnconfirmed = false
        }
        if let nonEmpty = health.lastNonEmptyCallbackAt, nonEmpty != lastObservedNonEmptyCallbackAt,
           speechRunStartedAt.map({ nonEmpty >= $0 }) ?? false {
            lastObservedNonEmptyCallbackAt = nonEmpty
            emptyOnlyRestartsInARow = 0
            unrequestedSpeechStops = []
        }
        refreshMediaReadiness()
        // Callback counts at ingress include coalesced partials.
        speechStatsChecks += 1
        if MetaDATSpeechStallPolicy.shouldLogStats(afterCheck: speechStatsChecks, reduced: reducedWork) {
            let window = MetaDATSpeechStallPolicy.statsSeconds(reduced: reducedWork)
            let counts = delivery.takeCallbackCounts()
            activityLogger?("speech events \(counts.total) (non-empty \(counts.nonEmpty)) in last \(window) s, state \(speech.state)")
            speechStatsChecks = 0
        }
        func seconds(_ instant: ContinuousClock.Instant?) -> TimeInterval? {
            guard let instant else { return nil }
            let duration = now - instant
            return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        }
        let action = MetaDATSpeechStallPolicy.action(
            sinceAnyEvent: MetaDATSpeechStallPolicy.evidenceAge(health.lastCallbackAt, runStartedAt: speechRunStartedAt, now: now),
            sinceNonEmpty: MetaDATSpeechStallPolicy.evidenceAge(health.lastNonEmptyCallbackAt, runStartedAt: speechRunStartedAt, now: now),
            speechStarted: health.isSDKReady,
            sessionStarted: health.sessionStarted,
            pausedByHost: speechPaused || speechStallRestarting,
            emptyOnlyLimit: MetaDATSpeechStallPolicy.emptyOnlyLimit(
                consecutiveEmptyRestarts: emptyOnlyRestartsInARow,
                sinceFreshStart: seconds(speechFreshStartAt)
            )
        )
        guard case let .restart(reason) = action, !stallStopUnconfirmed else { return true }
        if reason == .noEvents {
            guard MetaDATSpeechStallPolicy.canRecoverNoEvents(attempts: noEventRecoveryAttempts) else {
                if noEventRecoveryAttempts == MetaDATSpeechStallPolicy.noEventRecoveryLimit {
                    activityLogger?("speech no-event recovery limit reached; manual restart required")
                    noEventRecoveryAttempts += 1
                    refreshMediaReadiness()
                }
                return true
            }
            noEventRecoveryAttempts += 1
        } else if !MetaDATSpeechStallPolicy.canRecoverEmptyOnly(attempts: emptyOnlyRestartsInARow) {
            // True silence is ambiguous. Do not restart indefinitely.
            return true
        }
        speechStallRestarts += 1
        if reason == .emptyOnly { emptyOnlyRestartsInARow += 1 }
        activityLogger?("speech stall restart \(speechStallRestarts) (\(reason.rawValue))")
        speechStallRestarting = true
        refreshMediaReadiness()
        lastStallStopAt = Self.monotonicSeconds()
        defer {
            // A retired watchdog must not clear the next session's restart flag.
            if generationFence.owns(generation), self.speech === speech, speechDelivery === delivery {
                speechStallRestarting = false
                refreshMediaReadiness()
            }
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: MetaDATSpeechStallPolicy.stopConfirmationTimeout)
        speech.stop()
        do {
            try await Task.sleep(for: MetaDATSpeechStallPolicy.restartGap)
            while true {
                let decision = MetaDATSpeechStallPolicy.postStopAction(
                    ownsSpeech: generationFence.owns(generation) && self.speech === speech
                        && speechDelivery === delivery && !stopping,
                    cancelled: Task.isCancelled,
                    hostPaused: speechPaused,
                    sessionStarted: deviceSession?.state == .started,
                    speechStopped: speech.state == .stopped,
                    beforeDeadline: clock.now < deadline
                )
                switch decision {
                case .start:
                    markSpeechRestarted()
                    speech.start()
                    refreshMediaReadiness()
                    return true
                case .wait:
                    try await Task.sleep(for: MetaDATSpeechStallPolicy.stopConfirmationPoll)
                case .abandon:
                    if generationFence.owns(generation), self.speech === speech {
                        lastStallStopAt = nil
                        if !stopping, !speechPaused, sessionIsStarted, !Task.isCancelled {
                            // Do not keep issuing stop to a vendor object that
                            // never confirmed stop. New events or a fresh
                            // user/session start can re-arm the watchdog.
                            stallStopUnconfirmed = true
                            activityLogger?("speech stop confirmation timed out; recovery suspended")
                        }
                    }
                    return generationFence.owns(generation) && !Task.isCancelled
                }
            }
        } catch {
            if generationFence.owns(generation), self.speech === speech {
                lastStallStopAt = nil
            }
            return false
        }
    }

    /// The session came back from `.paused`: Speech that stopped meanwhile
    /// is not restarted by its own stop handler.
    private func handleSessionResumed(generation: UInt64) {
        guard !stopping, !speechStallRestarting, generationFence.owns(generation), let speech else { return }
        guard MetaDATSpeechStallPolicy.shouldRestartAfterSessionResumes(
            speechStopped: speech.state == .stopped,
            pausedByHost: speechPaused
        ) else { return }
        activityLogger?("speech restarted after session resumed")
        speechRestartAttempts = 0
        markSpeechRestarted()
        markSpeechFreshStart()
        speech.start()
        refreshMediaReadiness()
    }

    private func logSpeechLocale(_ locale: String, generation: UInt64, delivery: MetaDATSpeechTranscriptDelivery) {
        guard !stopping, generationFence.owns(generation), speechDelivery === delivery else { return }
        activityLogger?("speech locale \(locale)")
    }

    /// Stops DAT Speech but keeps the DeviceSession and the attached Speech
    /// (glasses taken off or folded). Idempotent.
    public func pauseSpeech() {
        guard !stopping, let speech, !speechPaused else { return }
        speechPaused = true
        markSpeechRestarted()
        refreshMediaReadiness()
        activityLogger?("speech paused")
        speech.stop()
    }

    /// Restarts the attached Speech after `pauseSpeech()`. Idempotent; a no-op
    /// when the session (and its Speech) is gone, which recovery handles.
    private func observeSessionState(_ state: DeviceSessionState, generation: UInt64) {
        guard !stopping, generationFence.owns(generation), let session = deviceSession else { return }
        let wasStarted = sessionIsStarted
        sessionIsStarted = session.state == .started
        if state == .paused {
            cameraSnapshotController.invalidate()
            markSpeechRestarted()
        }
        refreshMediaReadiness()
        // AWL never pauses the session itself, so a pause is the device's:
        // a single temple tap (or capture-button press) pauses a running
        // session (dat-ios #312). States only; tonight's test confirms it.
        if state == .paused {
            activityLogger?("session paused by device (likely tap)")
            if !sessionPauseReported {
                sessionPauseReported = true
                sessionPauseObserver?(true)
            }
        }
        if sessionIsStarted, !wasStarted || sessionPauseReported {
            markSpeechRestarted()
            markSpeechFreshStart()
            activityLogger?("session started")
            handleSessionResumed(generation: generation)
            if sessionPauseReported {
                sessionPauseReported = false
                sessionPauseObserver?(false)
            }
        }
    }

    public func resumeSpeech() {
        guard !stopping, let speech, speechPaused else { return }
        speechPaused = false
        speechRestartAttempts = 0
        activityLogger?("speech resumed")
        markSpeechRestarted()
        markSpeechFreshStart()
        // A paused DeviceSession, a still-stopping Speech, or the stall
        // watchdog owns the transition. The stopped/resumed callback can
        // start it once it is actually eligible.
        guard deviceSession?.state == .started, !speechStallRestarting, speech.state == .stopped else {
            refreshMediaReadiness()
            return
        }
        speech.start()
        refreshMediaReadiness()
    }

    public var isSpeechPaused: Bool { speechPaused }

    private static func observed(_ state: SpeechState) -> MetaDATSpeechRestartPolicy.ObservedState {
        switch state {
        case .started: return .started
        case .stopped: return .stopped
        default: return .transitioning
        }
    }

    private func handleSpeechState(_ state: SpeechState, generation: UInt64, delivery: MetaDATSpeechTranscriptDelivery) async {
        guard !stopping, generationFence.owns(generation), speechDelivery === delivery, let speech else { return }
        guard speech.state == state else { return }
        refreshMediaReadiness()
        activityLogger?("speech \(state)")
        let observed = Self.observed(state)
        // Vendor state callbacks hop through a Task; don't act on a stopped
        // notification if the actual Speech has already moved on.
        if observed == .stopped, speech.state != .stopped { return }
        switch MetaDATSpeechRestartPolicy.action(
            for: observed, attempts: speechRestartAttempts,
            // A stall restart's own stop, or a paused session, is not an
            // unrequested stop.
            paused: speechPaused || speechStallRestarting || !sessionIsStarted
                || (observed == .stopped && MetaDATSpeechRestartPolicy.isOwnStop(
                    sinceStallStop: lastStallStopAt.map { Self.monotonicSeconds() - $0 }
                ))
        ) {
        case .resetAttempts:
            speechRestartAttempts = 0
        case let .restart(attempt):
            speechRestartAttempts = attempt
            let now = Self.monotonicSeconds()
            unrequestedSpeechStops = MetaDATSpeechRestartPolicy.recent(unrequestedSpeechStops + [now], now: now)
            let wait = MetaDATSpeechRestartPolicy.restartDelay(recentUnrequestedStops: unrequestedSpeechStops.count)
            if wait > MetaDATSpeechRestartPolicy.delay {
                activityLogger?("speech stopped by itself \(unrequestedSpeechStops.count)x in 10 min — restarting in \(wait.components.seconds) s")
            }
            do { try await Task.sleep(for: wait) } catch { return }
            guard !Task.isCancelled, !stopping, !speechPaused, !speechStallRestarting,
                  deviceSession?.state == .started, generationFence.owns(generation),
                  speechDelivery === delivery, self.speech === speech else { return }
            // A resume or session resume during the wait may have started it.
            guard MetaDATSpeechRestartPolicy.shouldStartAfterWait(Self.observed(speech.state)) else {
                activityLogger?("speech restart \(attempt) skipped: already \(speech.state)")
                return
            }
            activityLogger?("speech restart \(attempt)")
            markSpeechRestarted()
            speech.start()
            refreshMediaReadiness()
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
        generation: UInt64,
        delivery: MetaDATSpeechTranscriptDelivery
    ) {
        guard !stopping, generationFence.owns(generation),
              speechDelivery === delivery, speech != nil else { return }

        // Speech is optional. A vendor transcript channel failure should only
        // retire Speech; a nil-ID .device error would retire the entire Core
        // runtime generation and unnecessarily drop healthy camera/agent work.
        liveCapabilities.update(speechReady: false)
        notifySpeechReadiness(false)
        speechStallTask?.cancel()
        speechStallTask = nil
        speechReviveTask?.cancel()
        speechReviveTask = nil
        if let speechLocaleToken { Task { await speechLocaleToken.cancel() } }
        speechLocaleToken = nil
        speechDelivery = nil
        delivery.cancel()
        speechTask?.cancel()
        speechTask = nil
        speech?.stop()
        speech = nil
        if let speechErrorToken {
            Task { await speechErrorToken.cancel() }
        }
        speechErrorToken = nil
        if let speechStateToken {
            Task { await speechStateToken.cancel() }
        }
        speechStateToken = nil
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

    private func emitDeviceError(_ error: DeviceSessionError, generation: UInt64) {
        guard !stopping, generationFence.owns(generation) else { return }
        // The case name only: the vendor description stays redacted.
        let kind = MetaDATSessionErrorKind(error)
        activityLogger?("session error: \(kind.rawValue)")
        sessionErrorObserver?(kind)
        // A non-blocking warning (dwaOutOfStuRange) must not retire a
        // healthy session.
        guard kind.response.endsSession else { return }
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
        speechDelivery?.cancel()
        speechDelivery = nil
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
        speechReviveTask?.cancel()
        speechReviveTask = nil
        speechStallRestarting = false
        noEventRecoveryAttempts = 0
        stallStopUnconfirmed = false
        lastStallStopAt = nil
        speechRunStartedAt = nil
        lastObservedCallbackAt = nil
        lastObservedNonEmptyCallbackAt = nil
        speechStatsChecks = 0
        sessionIsStarted = false
        notifySpeechReadiness(false)
        sessionPauseReported = false
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
