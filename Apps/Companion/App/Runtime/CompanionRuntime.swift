import AgentWearLinkAppleOutput
import AgentWearLinkCore
import AgentWearLinkMetaDATIntegration
import AgentWearLinkOpenClaw
import AVFoundation
import Foundation
import Speech
import Network
import SwiftUI
import UIKit

/// The companion app's single owner of the glasses ↔ Gateway connection.
///
/// It configures Meta Wearables, pairs once with the Gateway (setup code or
/// manual address), then keeps a voice session alive with the stored device
/// grant: auto-connect on launch, silent recovery with backoff, no
/// notifications. Whether listening is wanted at all is reconciled in one
/// serialized place, so quick toggles cannot leave it in a stale state.
@MainActor
final class CompanionRuntime: ObservableObject {
    enum PairingPhase: Equatable {
        case idle
        case connecting
        case waitingForApproval
        case succeeded
        case failed(PairingError)
    }

    enum PairingError: Equatable {
        case invalidCode, expiredCode, invalidAddress, insecureAddress
        case network, gateway, rejected, timedOut
    }

    /// Call practice: the last heard utterance and whether it woke the agent.
    struct PracticeState: Equatable {
        var transcript: String?
        var matched: Bool?
    }

    @Published var settings: CompanionSettings {
        didSet { settingsChanged(from: oldValue) }
    }
    @Published private(set) var signals = ConnectionSignals() {
        didSet { if !signalsFrozen { updateRecovery() } }
    }
    /// Quality counters and turn latencies (counts and durations only).
    @Published private(set) var quality = QualityMetrics()
    @Published private(set) var setup = SetupProgress()
    @Published private(set) var metaConfiguration: WearablesLink.Configuration?
    @Published private(set) var pairing: PairingPhase = .idle
    @Published private(set) var deviceID: String = ""
    @Published private(set) var practice = PracticeState()
    /// The Gateway's pairing request id while approval is pending, so the
    /// app can show the exact `openclaw devices approve <id>` command.
    @Published private(set) var pendingRequestID: String?
    @Published private(set) var isChecking = false
    @Published private(set) var lastCheckAt: Date?
    @Published private(set) var log = ActivityLog()

    var isListening: Bool {
        #if DEBUG
        if previewListening { return true }
        #endif
        return runtime != nil
    }
    var homeState: HomeViewState {
        HomeViewState(signals: signals, telegramConfigured: settings.isTelegramDeliveryConfigured)
    }
    /// Gateway hop name for the UI; "게이트웨이"/"Gateway" when unknown.
    /// Agent name for the UI; "에이전트"/"Agent" when unknown.
    var agentLabel: String {
        let name = settings.agentName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? String(localized: "에이전트") : name
    }
    var gatewayLabel: String {
        let name = settings.gatewayDisplayName
        return name.isEmpty ? String(localized: "게이트웨이") : name
    }

    private let store: CompanionSettingsStore
    private let startRequest = StartRequestFlag()
    private let wearables = WearablesLink()
    private let gatewayLink = GatewayLink()
    private let keepAlive = SilentKeepAlive()
    private let speaker = ReplySpeaker(language: CompanionRuntime.speechLanguage)
    private let calls = CallMonitor()
    private var callGate = CallGate()
    private let lifecycle = MetaDATApplicationLifecycle(initialPhase: .foreground)
    private let diagnostics = AWLDiagnosticRecorder(capacity: 256)
    private let pathMonitor = NWPathMonitor()
    private var pathSatisfied: Bool?
    private var appActive = true

    private var runtime: AgentWearLinkRuntime?
    private var device: MetaDATDeviceAdapter?
    /// EXPERIMENT glasses-mic wake adapter (no DAT session).
    private var micDevice: GlassesMicSpeechAdapter?
    /// Set only after the runtime started, so health checks never use a
    /// session whose dispatcher is not ready yet.
    private var voiceSession: GatewaySession?
    private var voiceConnecting = false
    private var wakeGate: WakeGateBox?
    private var latency = TurnLatencyTracker()
    private var stages = TurnStageTracker()
    private var recovery = RecoveryTracker()
    /// Speech is (re)starting after a deaf restart or a pause; not listening yet.
    private var speechRestartingSince: Date?
    private var lastFirstAudioMilliseconds: Int?
    /// The live reply sink, to drop the rest of a stopped reply.
    private var speechSink: StreamingSpeechOutput?
    private var connectionFence = AWLConnectionAttemptFence()
    private var disconnectInProgress = false

    private var recoveryTask: Task<Void, Never>?
    private var recoveryGeneration: UInt64 = 0
    private var reconcileChain: Task<Void, Never>?
    private var restartDebounce: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?
    private var pairingTask: Task<Void, Never>?
    private var pairingGeneration: UInt64 = 0
    private var periodicCheckTask: Task<Void, Never>?
    private var started = false
    /// DEBUG screenshot fixtures freeze the signals.
    private var signalsFrozen = false

    init(store: CompanionSettingsStore = CompanionSettingsStore()) {
        self.store = store
        let loaded = store.load()
        settings = loaded
        signals.listenEnabled = loaded.listenEnabled
        signals.lastReplyAt = loaded.lastReplyAt
        signals.lastReplyLatency = loaded.lastReplyLatency
        if loaded.setupCompleted {
            setup = SetupProgress(completed: Set(SetupStep.allCases))
        }
        keepAlive.onLog = { [weak self] line in self?.record(line) }
        keepAlive.onEvent = { [weak self] event in self?.handleAudioEvent(event) }
        speaker.setDucking = { [weak self] on in self?.keepAlive.setExperimentalDucking(on) }
        speaker.duckingMode = loaded.replyDucking
        speaker.voiceIdentifier = loaded.voiceIdentifier
        speaker.useGatewayVoice = loaded.gatewayVoice
        speaker.gatewayVoice = gatewayVoice
        gatewayVoice.play = { [weak keepAlive] buffer, done in keepAlive?.playSpeech(buffer, done: done) ?? false }
        gatewayVoice.outputFormat = { [weak keepAlive] in keepAlive?.speechFormat }
        gatewayVoice.stopPlayback = { [weak keepAlive] in keepAlive?.stopSpeech() }
        callGate = CallGate(callActive: calls.isCallActive)
        calls.onChange = { [weak self] active in
            Task { @MainActor in self?.callsChanged(active) }
        }
        keepAlive.isDATSessionLive = { [weak self] in
            guard let self else { return false }
            return self.runtime != nil || self.voiceConnecting
        }
        speaker.onEvent = { [weak self] line in self?.record(line) }
        speaker.onSilenced = { [weak self] in self?.signals.replyNotSpoken = true }
        speaker.onSpoken = { [weak self] in
            self?.signals.replyNotSpoken = false
            self?.followUp.replySpoken()
        }
        speaker.onIdle = { [weak self] in self?.replySpeechIdle() }
        speaker.onSystemAudioStarted = { [weak self] in self?.replyAudioStarted(.system) }
        gatewayVoice.onPlaybackStarted = { [weak self] in self?.replyAudioStarted(.gateway) }
    }

    private var wantsListening: Bool {
        ListeningPolicy.wantsListening(
            setupCompleted: settings.setupCompleted,
            listenEnabled: settings.listenEnabled,
            practicing: !settings.setupCompleted && setup.current == .practice
        )
    }

    // MARK: Launch and app phase

    /// Called once from the app's `.task`.
    func start() async {
        guard !started else { return }
        started = true
        // The intent can arrive with no view on screen (background launch).
        intentObserver = NotificationCenter.default.addObserver(
            forName: StartListeningIntent.notification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.startListeningFromIntent() }
        }
        // Normally already started in didFinishLaunching; idempotent.
        startWakeAnchor()
        #if DEBUG
        if CompanionPreviewFixture.apply(to: self) { return }
        #endif
        // A background launch (Shortcut, Bluetooth automation) must not
        // assume the foreground; the keep-alive watchdog retries if needed.
        appActive = UIApplication.shared.applicationState == .active
        startPathMonitor()
        let configuration = wearables.configure()
        metaConfiguration = configuration
        record("meta \(configuration)")
        wearables.observe { [weak self] in self?.refreshGlasses() }
        // App scope, independent of the session and the Gateway (Meta:
        // "open the stream early"); see WearablesLink.startVoiceInvocations.
        wearables.startVoiceInvocations(
            diagnostics: diagnostics,
            onLog: { [weak self] line in self?.record(line) },
            onLaunch: { [weak self] in self?.voiceInvocationLaunched() }
        )
        deviceID = (try? await gatewayLink.deviceID()) ?? ""
        refreshGlasses()
        signals.microphone = await wearables.microphonePermission()

        if startRequest.consume(), settings.setupCompleted, !settings.listenEnabled {
            // A Start Listening intent that arrived before the UI subscribed.
            settings.listenEnabled = true
        }
        if !settings.setupCompleted { await restoreSetupProgress() }
        consumeLaunchSetupCode()
        requestReconcile("launch", immediate: true)
        await checkNow()
        startPeriodicChecks()
    }

    /// The Meta lifecycle stays in the foreground phase while listening is
    /// wanted: the product promise is a voice session that survives the
    /// screen turning off. It follows the real app phase otherwise.
    func scenePhaseChanged(_ phase: ScenePhase) {
        guard phase != .inactive else { return }
        appActive = phase == .active
        Task {
            guard started, !signalsFrozen else { return }
            if appActive {
                await lifecycle.transition(to: .foreground)
                // The user may have just updated in Meta AI.
                if let hold = signals.hold, GlassesHoldPolicy.clearsOnForeground(hold) { setHold(nil, reason: "foreground") }
                refreshGlasses()
                if wantsListening {
                    // iOS only lets playback start in the foreground.
                    applyKeepAlivePolicy(force: true)
                    if runtime == nil { startRecovery("foreground", immediate: true, restart: true) }
                }
                await checkNow()
            } else if !wantsListening {
                await lifecycle.transition(to: .background)
            }
        }
    }

    func handleOpenURL(_ url: URL) {
        Task {
            if await wearables.handleCallback(url) {
                record("meta callback handled")
                refreshGlasses()
                if wearables.isRegistered { setup.complete(.metaRegistration) }
            }
        }
    }

    /// The app's runtime, set by the app delegate at launch, for the Start
    /// Listening intent (which may run with no view on screen).
    static weak var current: CompanionRuntime?

    /// Start Listening intent: starts listening and waits until a voice
    /// session is up, or `timeout`. An intent-launched app only gets
    /// execution time while `perform()` runs, so returning at once let a
    /// background launch suspend before anything connected.
    func startListeningAndWait(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        // A cold launch: start() runs from the delegate's Task.
        while !started, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        startListeningFromIntent()
        guard settings.setupCompleted else {
            record("start listening intent: setup not completed")
            return false
        }
        while !signals.listening, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(250))
        }
        record(signals.listening ? "start listening intent: listening" : "start listening intent: not listening yet")
        return signals.listening
    }

    /// Which mode the intent actually ran in (openAppWhenRun vs
    /// supportedModes on iOS 26+ is unverified).
    func noteIntentRun() {
        let state: String
        switch UIApplication.shared.applicationState {
        case .active: state = "foreground"
        case .inactive: state = "inactive"
        case .background: state = "background"
        @unknown default: state = "unknown"
        }
        record("start listening intent (app \(state))")
    }

    /// "Start listening" App Intent / App Shortcut.
    func startListeningFromIntent() {
        _ = startRequest.consume()
        guard started, settings.setupCompleted else { return }
        clearHoldOnUserRequest()
        if !settings.listenEnabled { settings.listenEnabled = true }
        if runtime == nil { startRecovery("start listening intent", immediate: true, restart: true) }
    }

    // MARK: Listening reconciliation

    /// Serializes start/stop so an off→on toggle during an in-flight stop
    /// still ends up listening.
    private func requestReconcile(_ reason: String, immediate: Bool = true, restartSession: Bool = false) {
        let previous = reconcileChain
        reconcileChain = Task { [weak self] in
            await previous?.value
            await self?.reconcile(reason, immediate: immediate, restartSession: restartSession)
        }
    }

    private func reconcile(_ reason: String, immediate: Bool, restartSession: Bool) async {
        guard !signalsFrozen else { return }
        updateWakeAnchor()
        if wantsListening {
            // May fail in the background; the keep-alive watchdog retries.
            applyKeepAlivePolicy(force: true)
            if restartSession, runtime != nil {
                record("restart: \(reason)")
                await disconnectVoice()
                listeningLost("restart: \(reason)")
                // No DAT session now: safe to reactivate audio if needed.
                applyKeepAlivePolicy(force: true)
                // A new DAT session too soon after a stop fails (dat-ios #231).
                startRecovery(reason, immediate: false, restart: true)
            } else if runtime == nil {
                startRecovery(reason, immediate: immediate, restart: false)
            }
        } else {
            cancelRecovery()
            await disconnectVoice()
            keepAlive.stop()
            if !appActive { await lifecycle.transition(to: .background) }
        }
    }

    // MARK: Setup

    private func restoreSetupProgress() async {
        var progress = SetupProgress()
        if wearables.isRegistered { progress.complete(.metaRegistration) }
        if signals.microphone == .granted { progress.complete(.microphone) }
        if let endpoint = currentEndpoint, await gatewayLink.grantStatus(for: endpoint) == .approved {
            progress.complete(.tailscale)
            progress.complete(.gateway)
        }
        setup = progress
    }

    func registerWithMeta() async {
        guard wearables.isConfigured else { return }
        if wearables.isRegistered {
            setup.complete(.metaRegistration)
            return
        }
        let started = await wearables.startRegistration()
        record(started ? "meta registration requested" : "meta registration failed")
    }

    func requestMicrophone() async {
        let result = await wearables.requestMicrophone()
        signals.microphone = result
        record("microphone \(result)")
        if result == .granted { setup.complete(.microphone) }
    }

    func completeStep(_ step: SetupStep) {
        setup.complete(step)
        if step == .gateway {
            practice = PracticeState()
            requestReconcile("call practice")
        }
    }

    func skipStep(_ step: SetupStep) {
        setup.skip(step)
        if setup.isFinished { finishSetup() }
    }

    func finishSetup() {
        setup = SetupProgress(completed: Set(SetupStep.allCases))
        settings.setupCompleted = true
        practice = PracticeState()
        requestReconcile("setup finished")
        Task { await checkNow() }
    }

    // MARK: Pairing

    func pair(setupCode raw: String) {
        do {
            let code = try OpenClawSetupCode(raw)
            let endpoint = try GatewayAddress.endpoint(for: code.url)
            runPairing(
                endpoint: endpoint,
                credentials: .init(bootstrapToken: code.bootstrapToken),
                codeExpiresAt: code.expiresAt
            )
        } catch OpenClawSetupCodeError.expired {
            pairing = .failed(.expiredCode)
        } catch GatewayAddressError.insecure {
            pairing = .failed(.insecureAddress)
        } catch {
            pairing = .failed(.invalidCode)
        }
    }

    /// USB pairing (see `LaunchSetupCode`). The code itself is never logged.
    private func consumeLaunchSetupCode() {
        let arguments = ProcessInfo.processInfo.arguments
        if let key = LaunchArgument.value(LaunchArgument.sessionKey, in: arguments), key != settings.sessionKey {
            settings.sessionKey = key
            record("settings: session key from the connected computer")
        }
        if let chat = LaunchArgument.value(LaunchArgument.telegramChatID, in: arguments),
           CompanionTurnOptions.isTelegramChatID(chat),
           chat != settings.telegramChatID || !settings.telegramEnabled {
            settings.telegramChatID = chat
            settings.telegramEnabled = true
            record("settings: Telegram chat from the connected computer")
        }
        guard let code = LaunchSetupCode.value(in: arguments) else { return }
        record("pairing: setup code from the connected computer")
        pair(setupCode: code)
    }

    func pair(address: String, oneTimeToken: String) {
        let token = oneTimeToken.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let endpoint = try GatewayAddress.endpoint(fromUserInput: address)
            runPairing(endpoint: endpoint, credentials: .init(token: token.isEmpty ? nil : token), codeExpiresAt: nil)
        } catch GatewayAddressError.insecure {
            pairing = .failed(.insecureAddress)
        } catch {
            pairing = .failed(.invalidAddress)
        }
    }

    func cancelPairing() {
        pairingGeneration &+= 1
        pairingTask?.cancel()
        pairingTask = nil
        pairing = .idle
    }

    /// Connects, and while the Gateway answers "pairing required" keeps
    /// retrying quietly until the device is approved on the host or the
    /// setup code expires. The one-time credential lives only in this task.
    /// Every state write is fenced by a generation so a cancelled or older
    /// attempt can never overwrite a newer one.
    /// "다시 시도" after a failed pairing: the last attempt's parameters
    /// live only in memory for this purpose.
    private var lastPairingAttempt: (OpenClawEndpoint, OpenClawConnectCredentials, Date?)?

    var canRetryPairing: Bool {
        guard let attempt = lastPairingAttempt else { return false }
        if let expiry = attempt.2, expiry <= Date() { return false }
        return true
    }

    func retryPairing() {
        guard let (endpoint, credentials, expiry) = lastPairingAttempt else {
            pairing = .idle
            return
        }
        runPairing(endpoint: endpoint, credentials: credentials, codeExpiresAt: expiry)
    }

    /// Back to the scanner, e.g. after an expired code.
    func resetPairing() {
        cancelPairing()
        lastPairingAttempt = nil
    }

    private func runPairing(
        endpoint: OpenClawEndpoint,
        credentials: OpenClawConnectCredentials,
        codeExpiresAt: Date?
    ) {
        lastPairingAttempt = (endpoint, credentials, codeExpiresAt)
        pendingRequestID = nil
        pairingTask?.cancel()
        pairingGeneration &+= 1
        let generation = pairingGeneration
        pairing = .connecting
        record("pairing started (\(endpoint.exposure.rawValue))")
        pairingTask = Task { [weak self] in
            let startedAt = Date()
            @MainActor func current() -> CompanionRuntime? {
                guard let self, !Task.isCancelled, self.pairingGeneration == generation else { return nil }
                return self
            }
            while let runtime = current() {
                switch PairingRetry.next(now: Date(), startedAt: startedAt, codeExpiresAt: codeExpiresAt) {
                case .codeExpired:
                    runtime.record("pairing stopped: setup code expired")
                    runtime.pairing = .failed(.expiredCode)
                    return
                case .timedOut:
                    runtime.pairing = .failed(.timedOut)
                    return
                case .retry:
                    break
                }
                do {
                    let session = try runtime.gatewayLink.makeSession(
                        endpoint: endpoint, credentials: credentials, diagnostics: runtime.diagnostics
                    )
                    do {
                        try await session.supervisor.start()
                    } catch {
                        await session.supervisor.stop()
                        throw error
                    }
                    let name = await session.agentName(sessionKey: runtime.sessionKeyOrNil)
                    await session.supervisor.stop()
                    let grant = await runtime.gatewayLink.grantStatus(for: endpoint)
                    guard let runtime = current() else { return }
                    guard grant == .approved else {
                        runtime.record("pairing finished without a write grant")
                        runtime.pairing = .failed(.rejected)
                        return
                    }
                    runtime.settings.gatewayURL = endpoint.gatewayURL.absoluteString
                    if let name, !name.isEmpty { runtime.settings.agentName = name }
                    runtime.pairing = .succeeded
                    runtime.signals.network = .reachable
                    runtime.signals.gateway = .ok
                    runtime.record("pairing approved")
                    return
                } catch {
                    guard let runtime = current() else { return }
                    switch GatewayFailure.classify(error, usedStoredGrant: false) {
                    case .pairingPending:
                        if case let OpenClawHandshakeError.pairingRequired(request) = error,
                           let id = request.requestID, !id.isEmpty {
                            runtime.pendingRequestID = id
                        }
                        if runtime.pairing != .waitingForApproval {
                            runtime.record("waiting for approval on the host")
                        }
                        runtime.pairing = .waitingForApproval
                        try? await Task.sleep(for: .seconds(PairingRetry.interval))
                    case .networkUnreachable:
                        runtime.record("pairing failed: network")
                        runtime.pairing = .failed(.network)
                        return
                    case .pairingRevoked:
                        runtime.pairing = .failed(.rejected)
                        return
                    case .gatewayUnreachable:
                        runtime.record("pairing failed: gateway")
                        runtime.pairing = .failed(.gateway)
                        return
                    }
                }
            }
        }
    }

    // MARK: Settings actions

    /// "승인만 다시 받기".
    func reapprove() async {
        await stopEverything()
        if let endpoint = currentEndpoint { await gatewayLink.forgetGrant(for: endpoint) }
        settings.setupCompleted = false
        setup.restartGatewayApproval()
        pairing = .idle
        signals.gateway = .unknown
        record("grant forgotten; approve again")
    }

    /// "모두 지우고 처음부터".
    func resetEverything() async {
        await stopEverything()
        await gatewayLink.forgetEverything(endpoint: currentEndpoint)
        wakeAnchor.forget()
        store.reset()
        settings = store.load()
        deviceID = (try? await gatewayLink.deviceID()) ?? ""
        signals = ConnectionSignals()
        pairing = .idle
        practice = PracticeState()
        lastCheckAt = nil
        await restoreSetupProgress()
        record("reset")
    }

    /// Audio-session events: interruptions (calls end the DAT session on
    /// current firmware), media-services resets and route changes.
    private func handleAudioEvent(_ event: SilentKeepAlive.Event) {
        let mapped: AudioEventPolicy.Event
        switch event {
        case .interruptionEnded: mapped = .interruptionEnded
        case .mediaServicesReset: mapped = .mediaServicesReset
        case .routeChanged: mapped = .routeChanged
        }
        let actions = AudioEventPolicy.actions(for: mapped, listeningWanted: wantsListening)
        if actions.restartKeepAlive { applyKeepAlivePolicy(force: true) }
        if actions.recreateSynthesizer { speaker.recreate() }
        if actions.recoverSessionNow {
            if runtime == nil {
                startRecovery("audio \(mapped)", immediate: true, restart: true)
            } else {
                requestReconcile("audio \(mapped)", restartSession: true)
            }
        }
    }

    /// "다시 시작": rebuild the voice session now.
    func restartListening() {
        signals.listenFailed = false
        clearHoldOnUserRequest()
        if !settings.listenEnabled {
            settings.listenEnabled = true
        } else if runtime != nil {
            requestReconcile("restart requested", restartSession: true)
        } else {
            startRecovery("restart requested", immediate: true, restart: true)
        }
    }

    /// Call practice: make what the recognizer heard a wake phrase, then
    /// re-evaluate that utterance so the result shows right away.
    func addPracticeWakePhrase(_ phrase: String) {
        settings.addWakePhrase(phrase)
        guard let transcript = practice.transcript else { return }
        let decision = AWLWakePhraseGate(wakePhrases: settings.effectiveWakePhrases).evaluate(transcript)
        practice.matched = decision != .ignore
        record("wake phrase added from practice")
    }

    private func stopEverything() async {
        cancelRecovery()
        restartDebounce?.cancel()
        await reconcileChain?.value
        await disconnectVoice()
        keepAlive.stop()
    }

    func copyDiagnostics() {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        var text = log.export { formatter.string(from: $0) }
        if let evidence = try? AWLDiagnosticEvidence.export(from: diagnostics, maximumEvents: 128) {
            text += "\n\n" + evidence
        }
        UIPasteboard.general.string = text
    }

    private func settingsChanged(from old: CompanionSettings) {
        signals.listenEnabled = settings.listenEnabled
        // DEBUG screenshot fixtures must never overwrite real settings.
        guard !signalsFrozen else { return }
        store.save(settings)
        guard started else { return }
        if old.listenEnabled != settings.listenEnabled || old.setupCompleted != settings.setupCompleted {
            requestReconcile(settings.listenEnabled ? "listening on" : "listening off")
        }
        if old.replyDucking != settings.replyDucking { speaker.duckingMode = settings.replyDucking }
        if old.voiceIdentifier != settings.voiceIdentifier { speaker.voiceIdentifier = settings.voiceIdentifier }
        if old.gatewayVoice != settings.gatewayVoice { speaker.useGatewayVoice = settings.gatewayVoice }
        if old.wakeSource != settings.wakeSource, runtime != nil {
            record("wake source: \(settings.wakeSource.rawValue)")
            requestReconcile("wake source changed", restartSession: true)
        }
        if old.effectiveWakePhrases != settings.effectiveWakePhrases, let wakeGate {
            let phrases = settings.effectiveWakePhrases
            Task { await wakeGate.replacePhrases(phrases) }
        }
        let turnOptionsChanged = CompanionTurnOptions.make(from: old) != CompanionTurnOptions.make(from: settings)
            || old.sessionKey != settings.sessionKey || old.visionRequests != settings.visionRequests
        if turnOptionsChanged, runtime != nil {
            // Coalesce bursts of edits into one restart.
            restartDebounce?.cancel()
            restartDebounce = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                self?.requestReconcile("turn options changed", restartSession: true)
            }
        }
    }

    // MARK: Health check

    /// "지금 다시 확인": glasses state, route and Gateway health. Never an
    /// agent turn (that would add to the chat and spend quota).
    func checkNow() async {
        guard !isChecking, !signalsFrozen else { return }
        isChecking = true
        defer { isChecking = false }
        refreshGlasses()
        let microphone = await wearables.microphonePermission()
        if microphone != .unknown { signals.microphone = microphone }
        let now = Date()
        signals.checkedAt[.phone] = now
        defer { lastCheckAt = Date() }

        guard let endpoint = currentEndpoint else { return }
        if pathSatisfied == false {
            GatewayFailure.networkUnreachable.apply(to: &signals, at: now)
            return
        }
        // A voice session is starting: its own result will update the
        // Gateway hops. Never race it with a second session.
        if voiceConnecting { return }
        do {
            if let voiceSession {
                try await voiceSession.health()
            } else {
                switch await gatewayLink.grantStatus(for: endpoint) {
                case .missing:
                    GatewayFailure.pairingRevoked.apply(to: &signals, at: now)
                    return
                case .unavailable:
                    record("check: keychain unavailable, retry later")
                    return
                case .approved:
                    break
                }
                let session = try gatewayLink.makeSession(
                    endpoint: endpoint, credentials: .init(), diagnostics: diagnostics
                )
                do {
                    try await session.supervisor.start()
                    try await session.health()
                    if let name = await session.agentName(sessionKey: sessionKeyOrNil), !name.isEmpty,
                       name != settings.agentName {
                        settings.agentName = name
                    }
                    await session.supervisor.stop()
                } catch {
                    await session.supervisor.stop()
                    throw error
                }
            }
            markGatewayHealthy()
        } catch {
            let failure = GatewayFailure.classify(error, usedStoredGrant: true)
            record("check: \(failure.rawValue)")
            failure.apply(to: &signals, at: Date())
        }
    }

    private func markGatewayHealthy() {
        signals.network = .reachable
        signals.gateway = .ok
        signals.checkedAt[.network] = Date()
        signals.checkedAt[.gateway] = Date()
    }

    private func startPeriodicChecks() {
        periodicCheckTask?.cancel()
        periodicCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self, !Task.isCancelled else { return }
                self.applyKeepAlivePolicy()
                self.appendPowerSample()
                if self.appActive {
                    await self.checkNow()
                } else {
                    // Device state is push-only: re-evaluate the thermal
                    // dwell and any reconnect hold once a minute.
                    self.refreshGlasses()
                }
            }
        }
    }

    // MARK: Gateway voice

    private let gatewayVoice = GatewayVoice()

    /// Points the gateway voice at the live session (nil: not connected).
    private func bindGatewayVoice(_ session: GatewaySession?) {
        guard let session else {
            gatewayVoice.render = nil
            return
        }
        let client = OpenClawAgentRunClient(dispatcher: session.dispatcher)
        gatewayVoice.render = { text in try await client.speak(text: text) }
        gatewayVoice.onLog = { [weak self] line in self?.record(line) }
    }

    // MARK: Bluetooth wake

    private let wakeAnchor = GlassesWakeAnchor()
    private var intentObserver: NSObjectProtocol?

    func noteBluetoothRelaunch() { record("relaunched by Bluetooth") }

    /// Creates the Bluetooth wake anchor. Called synchronously from
    /// `didFinishLaunching`, so a CoreBluetooth restore relaunch re-creates
    /// the manager where Apple expects it; idempotent.
    func startWakeAnchor() {
        #if DEBUG
        if CompanionPreviewFixture.isActive { return }
        #endif
        guard !wakeAnchorStarted else { return }
        wakeAnchorStarted = true
        wakeAnchor.onLog = { [weak self] line in self?.record(line) }
        wakeAnchor.onLinked = { [weak self] in self?.glassesLinked() }
        wakeAnchor.onUnlinked = { [weak self] in self?.record("glasses link down") }
        wakeAnchor.start(active: anchorWanted)
    }

    private var wakeAnchorStarted = false

    private var anchorWanted: Bool {
        WakeAnchorBackoff.shouldAnchor(setupCompleted: settings.setupCompleted, listenEnabled: settings.listenEnabled)
    }

    /// Holds the glasses link only while listening is wanted after setup.
    private func updateWakeAnchor() {
        guard wakeAnchorStarted else { return }
        wakeAnchor.setActive(anchorWanted)
    }

    /// The glasses' Bluetooth link came back (possibly waking a suspended
    /// app): keep the app awake and reconnect, like opening the app would.
    private func glassesLinked() {
        glassesLastSeenAt = Date()
        guard started, wantsListening else { return }
        // A Bluetooth wake gives the app ~10 s; ask for more until the
        // keep-alive runs and the first connect attempt is under way.
        if runtime == nil { beginWakeBackgroundTask() }
        applyKeepAlivePolicy(force: true)
        refreshGlasses()
        if runtime == nil { startRecovery("glasses linked", immediate: true, restart: false) }
    }

    private var wakeBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var wakeBackgroundTimeout: Task<Void, Never>?
    static let wakeBackgroundSeconds: TimeInterval = 25

    private func beginWakeBackgroundTask() {
        guard wakeBackgroundTask == .invalid else { return }
        wakeBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "glasses wake") { [weak self] in
            MainActor.assumeIsolated { self?.endWakeBackgroundTask("expired") }
        }
        guard wakeBackgroundTask != .invalid else { return }
        record("glasses wake: background time requested")
        wakeBackgroundTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.wakeBackgroundSeconds))
            guard !Task.isCancelled else { return }
            self?.endWakeBackgroundTask("timeout")
        }
    }

    private func endWakeBackgroundTask(_ reason: String) {
        guard wakeBackgroundTask != .invalid else { return }
        wakeBackgroundTimeout?.cancel()
        wakeBackgroundTimeout = nil
        UIApplication.shared.endBackgroundTask(wakeBackgroundTask)
        wakeBackgroundTask = .invalid
        record("glasses wake: background time ended (\(reason))")
    }

    // MARK: Keep-alive policy

    private var glassesLastSeenAt: Date?

    /// Stops the silent keep-alive when it only keeps an idle app awake
    /// (no glasses for a while, in the background); restarts it when needed.
    /// `force` re-issues start() (idempotent) when the policy allows, for
    /// callers that know the engine may have stopped.
    private func applyKeepAlivePolicy(force: Bool = false) {
        guard started, !signalsFrozen else { return }
        let now = Date()
        let glassesConnected = signals.glasses == .connected
        glassesLastSeenAt = KeepAlivePolicy.lastSeen(
            previous: glassesLastSeenAt, now: now,
            glassesConnected: glassesConnected, voiceSessionLive: runtime != nil
        )
        let sinceGlassesSeen = glassesLastSeenAt.map { now.timeIntervalSince($0) }
        let run = KeepAlivePolicy.shouldRun(
            wantsListening: wantsListening,
            voiceSessionActive: runtime != nil || voiceConnecting,
            glassesConnected: glassesConnected,
            appActive: appActive,
            sinceGlassesSeen: sinceGlassesSeen,
            wakeAnchored: wakeAnchor.anchoredCount > 0
        )
        if !run, keepAlive.isRunning || keepAliveWanted {
            keepAliveWanted = false
            record(KeepAlivePolicy.offReason(wantsListening: wantsListening, sinceGlassesSeen: sinceGlassesSeen))
            keepAlive.stop()
        } else if run, !keepAliveWanted || force {
            keepAliveWanted = true
            keepAlive.start()
        }
    }

    /// Mirrors whether the policy last asked the keep-alive to run.
    private var keepAliveWanted = true

    // MARK: Power log

    private var speechStallRestartCount = 0
    private var turnCount = 0
    private let powerLog = PowerLogFile(
        url: (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory).appendingPathComponent("power-log.csv")
    )

    /// One line a minute, also in the background while the keep-alive runs.
    private func appendPowerSample() {
        let now = Date()
        // Safety net: a restart whose "speech started" never logged.
        if let since = speechRestartingSince, now.timeIntervalSince(since) > 90 { speechRestartingSince = nil }
        quality.minute(worn: shouldListenNow, listening: listeningUp, at: now)
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType.rawValue).joined(separator: "+")
        powerLog.append(PowerSample(
            time: Date(),
            glassesBattery: signals.glassesBattery,
            glassesCharging: signals.glassesCharging,
            listening: signals.listening,
            speechPause: String(describing: signals.speechPause),
            keepAliveRunning: keepAlive.isRunning,
            outputs: outputs,
            appActive: appActive,
            phoneLocked: !UIApplication.shared.isProtectedDataAvailable,
            speechStallRestarts: speechStallRestartCount,
            turns: turnCount,
            quality: quality.sinceLaunch,
            lastLatencyFirstAudioMilliseconds: lastFirstAudioMilliseconds,
            lastPhotoCaptureMilliseconds: quality.lastPhotoCapture.map { Int(($0 * 1000).rounded()) }
        ))
    }

    private func startPathMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in self?.pathSatisfied = satisfied }
        }
        pathMonitor.start(queue: DispatchQueue(label: "dev.agentwearlink.companion.path"))
    }

    private func refreshGlasses() {
        guard !signalsFrozen, metaConfiguration != nil else { return }
        let devices = wearables.observedDevices()
        let snapshot = GlassesStateMapper.snapshot(registered: wearables.isRegistered, devices: devices)
        signals.glasses = snapshot.glasses
        signals.glassesUpdate = snapshot.update
        if snapshot.glasses == .connected { glassesLastSeenAt = Date() }
        applyKeepAlivePolicy()
        signals.glassesBattery = snapshot.battery
        signals.glassesCharging = snapshot.charging
        signals.checkedAt[.glasses] = Date()
        if !settings.setupCompleted, wearables.isRegistered, setup.current == .metaRegistration {
            setup.complete(.metaRegistration)
        }
        if lowBatteryNotice.update(battery: snapshot.battery, charging: snapshot.charging) {
            // Logged once; listening goes on (the owner decides later).
            record("glasses battery low (\(snapshot.battery ?? 0)%)")
        }
        if signals.glassesBatteryLow != lowBatteryNotice.active { signals.glassesBatteryLow = lowBatteryNotice.active }
        let thermal = GlassesStateMapper.thermal(devices)
        applyThermalStage(thermal)
        if let hold = signals.hold, GlassesHoldPolicy.shouldRelease(
            hold, thermal: thermal, battery: snapshot.battery, charging: snapshot.charging, now: Date()
        ) {
            setHold(nil, reason: "thermal \(thermal), battery \(snapshot.battery.map(String.init) ?? "?")\(snapshot.charging ? " charging" : "")")
        }
        applySpeechPower(GlassesStateMapper.speechDecision(devices, thermalStage: thermalStage.stage))
    }

    // MARK: Thermal, battery and reconnect holds

    private var thermalStage = ThermalStageTracker()
    private var lowBatteryNotice = LowBatteryNotice()

    /// Meta's thermal guidance: LIGHT changes nothing, MODERATE reduces
    /// optional work (cues, voice prefetch, stats), SEVERE+ sheds Speech
    /// (applySpeechPower). Hysteresis lives in ThermalStageTracker.
    private func applyThermalStage(_ level: SpeechPowerPolicy.Thermal) {
        guard let stage = thermalStage.update(level: level, at: Date()) else { return }
        record("thermal stage: \(stage) (level \(level))")
        applyReducedWork()
    }

    private func applyReducedWork() {
        let stage = thermalStage.stage
        gatewayVoice.prefetchLimit = ThermalWorkPolicy.gatewayVoicePrefetchLimit(stage: stage)
        let reduced = ThermalWorkPolicy.reducesSpeechStats(stage: stage)
        if let device { Task { await device.setReducedWork(reduced) } }
    }

    /// A DeviceSessionError from the live session or a failed connect.
    /// The case name is logged by the adapter (never the vendor text).
    private func handleSessionError(_ kind: MetaDATSessionErrorKind) {
        let now = Date()
        switch kind.response {
        case .continueSession:
            // Meta: not blocking; the session goes on.
            record("session warning ignored: \(kind.rawValue)")
        case .reconnect:
            break
        case .coolDown:
            setHold(.coolingDown(since: now), reason: kind.rawValue)
        case .waitForCharge:
            setHold(.charging(since: now, battery: signals.glassesBattery), reason: kind.rawValue)
        case .updateGlassesApp:
            setHold(.update(.glassesApp, since: now), reason: kind.rawValue)
        case .updateCompanionApp:
            setHold(.update(.companionApp, since: now), reason: kind.rawValue)
        }
    }

    private func setHold(_ hold: GlassesHold?, reason: String) {
        guard signals.hold != hold else { return }
        let previous = signals.hold
        signals.hold = hold
        if let hold {
            signals.listenFailed = false
            record("reconnect held: \(hold.logName) (\(reason))")
        } else if let previous {
            record("reconnect hold released: \(previous.logName) (\(reason))")
        }
    }

    /// An explicit request ("다시 시작", intent, "Hey Meta, start …") ends
    /// a charge or update hold; heat is never overridden.
    private func clearHoldOnUserRequest() {
        guard let hold = signals.hold, GlassesHoldPolicy.clearsOnUserRequest(hold) else { return }
        setHold(nil, reason: "requested")
    }

    /// "Hey Meta, start <app>": already acknowledged by the channel. Same
    /// path as the Start Listening intent; when a session is already up,
    /// arm the gate like a double tap so the wearer can speak right away.
    private func voiceInvocationLaunched() {
        record("voice invocation: launch app")
        guard started, settings.setupCompleted else { return }
        if runtime == nil {
            beginWakeBackgroundTask()
            startListeningFromIntent()
        } else if let wakeGate {
            Task {
                await wakeGate.arm()
                record("armed by voice invocation")
                playCue(.listening)
            }
        }
    }

    /// Stops DAT Speech when the glasses are taken off, folded or too hot,
    /// and restarts it when usable again, keeping the DAT session: a session
    /// ended by a doff/fold can refuse new starts until a power cycle
    /// (dat-ios #292). Only a real link drop / session stop tears down.
    private func applySpeechPower(_ decision: SpeechPowerPolicy.Decision, force: Bool = false) {
        let previous = signals.speechPause
        if previous != .listen, decision == .listen, device != nil {
            // Listening is back only once Speech has really started again
            // (set before the signal changes, which updates recovery).
            speechRestartingSince = Date()
        }
        signals.speechPause = decision
        guard force || decision != previous else { return }
        if decision != previous { record("speech power: \(decision)") }
        if previous == .listen, decision != .listen {
            listeningLost(decision == .shedThermal ? "thermal pause" : "doff/fold pause")
        }
        guard let device else { return }
        Task {
            if decision == .listen {
                await device.resumeSpeech()
            } else {
                await device.pauseSpeech()
            }
        }
    }

    private func callsChanged(_ active: Bool) {
        defer { updateRecovery() }
        switch callGate.update(callActive: active) {
        case .callStarted:
            record("call started: reconnects paused")
        case .lastCallEnded:
            record("last call ended: recovering")
            // Calls end the DAT session on current firmware (#332): rebuild
            // now, after the usual settle, instead of waiting for backoff.
            guard wantsListening else { return }
            if runtime == nil {
                startRecovery("call ended", immediate: false, restart: true)
            } else {
                requestReconcile("call ended", restartSession: true)
            }
        case .none:
            break
        }
    }

    // MARK: Recovery

    private var currentEndpoint: OpenClawEndpoint? {
        try? GatewayAddress.endpoint(fromUserInput: settings.gatewayURL)
    }

    private var sessionKeyOrNil: String? {
        let key = settings.sessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    private enum ConnectOutcome { case connected, retry, needsApproval }

    /// Waits quietly until the glasses are actually connected (not merely
    /// paired and folded in the case), settles, then connects with the stored
    /// grant, backing off on failures. Never notifies the user.
    /// - Parameter restart: replace a running recovery loop (e.g. returning
    ///   to the foreground should not wait out a 60 s backoff).
    private func startRecovery(_ reason: String, immediate: Bool, restart: Bool) {
        guard wearables.isConfigured, runtime == nil else { return }
        if recoveryTask != nil {
            guard restart else { return }
            recoveryTask?.cancel()
        }
        recoveryGeneration &+= 1
        let generation = recoveryGeneration
        record("recovery: \(reason)")
        recoveryTask = Task { [weak self] in
            var attempt = 0
            var settle = !immediate
            while !Task.isCancelled {
                guard let self else { return }
                // Connected glasses (Speech pause/resume handles doff/fold).
                await self.wearables.waitForConnectedDevice()
                // No reconnect attempts during a call (#332): wait quietly.
                while !Task.isCancelled, !self.callGate.allowsReconnect {
                    try? await Task.sleep(for: .seconds(2))
                }
                if Task.isCancelled { break }
                // Cooling down, waiting for charge or an update: no session
                // attempts until the hold is released, then start over.
                if self.signals.hold != nil {
                    await self.waitWhileHeld()
                    attempt = 0
                    settle = true
                    continue
                }
                if settle {
                    try? await Task.sleep(for: .seconds(RecoveryPolicy.settleDelay))
                }
                settle = true
                guard !Task.isCancelled, self.wantsListening, self.runtime == nil else { break }
                let outcome = await self.connectVoice()
                // Glasses are on but no session came up: say so on Home.
                self.signals.listenFailed = outcome == .retry && self.wearables.hasConnectedDevice
                    && self.signals.hold == nil
                if outcome != .retry { break }
                let delay = RecoveryPolicy.delay(afterFailedAttempt: attempt)
                attempt += 1
                try? await Task.sleep(for: .seconds(delay))
            }
            // Only the loop that is still current may clear the slot.
            if let self, self.recoveryGeneration == generation { self.recoveryTask = nil }
        }
    }

    /// Polls the local device state (no session attempts) until the hold
    /// is released by refreshGlasses or cleared by the user.
    private func waitWhileHeld() async {
        while !Task.isCancelled, signals.hold != nil {
            refreshGlasses()
            if signals.hold == nil { return }
            try? await Task.sleep(for: .seconds(5))
        }
    }

    private func cancelRecovery() {
        recoveryGeneration &+= 1
        recoveryTask?.cancel()
        recoveryTask = nil
    }

    // MARK: Voice session

    private func connectVoice() async -> ConnectOutcome {
        guard runtime == nil, !connectionFence.isStarting, !disconnectInProgress,
              wearables.isRegistered, let endpoint = currentEndpoint else { return .retry }
        switch await gatewayLink.grantStatus(for: endpoint) {
        case .missing:
            signals.gateway = .pairingRevoked
            signals.checkedAt[.gateway] = Date()
            record("connect stopped: no approved grant")
            return .needsApproval
        case .unavailable:
            record("connect deferred: keychain unavailable")
            return .retry
        case .approved:
            break
        }
        guard let attempt = connectionFence.begin() else { return .retry }
        // The only safe moment to (re)activate the audio session (#292).
        keepAlive.prepareForDATSession()
        voiceConnecting = true
        defer {
            voiceConnecting = false
            connectionFence.finish(attempt)
        }

        let session: GatewaySession
        do {
            session = try gatewayLink.makeSession(endpoint: endpoint, credentials: .init(), diagnostics: diagnostics)
        } catch {
            record("connect failed: invalid endpoint")
            return .needsApproval
        }
        let agent = OpenClawNativeAgentAdapter(
            supervisor: session.supervisor,
            dispatcher: session.dispatcher,
            runClient: OpenClawAgentRunClient(dispatcher: session.dispatcher),
            sessionKey: sessionKeyOrNil,
            // Image turns happen only through PhotoTurnAgent (DAT path);
            // the Gateway's attachment policy is still checked per turn.
            supportsVisionInput: true,
            visionSystemPrompt: PhotoTurnText.visionHint,
            turnOptions: CompanionTurnOptions.make(from: settings)
        )
        if settings.wakeSource == .glassesMicOnPhone {
            return await connectGlassesMic(session: session, agent: agent, attempt: attempt)
        }
        speaker.allowHandsFree = false
        let concreteDevice = MetaDATDeviceAdapter(applicationLifecycle: lifecycle, diagnostics: diagnostics)
        let gate = WakeGateBox(phrases: settings.effectiveWakePhrases)
        speaker.gate = gate
        let sink = StreamingSpeechOutput(synthesizer: speaker)
        speechSink = sink
        await configureDevice(concreteDevice, gate: gate)
        await concreteDevice.setReducedWork(ThermalWorkPolicy.reducesSpeechStats(stage: thermalStage.stage))

        let output: @Sendable (InteractionEvent) async -> Void = { [weak self] event in
            await sink.consume(event)
            await self?.observeOutput(event, attempt: attempt)
        }
        // Device first: if the glasses dropped again, fail there without
        // dialling the Gateway.
        // "이거 뭐야?": visual requests take one photo first (PhotoTurnAgent).
        let photoAgent = PhotoTurnAgent(
            inner: agent,
            enabled: settings.visionRequests,
            capture: { [weak self] id in
                await self?.capturePhotoForTurn(id) ?? .unavailable(reason: "no runtime")
            },
            observe: { [weak self] event in
                Task { @MainActor in self?.observePhotoTurn(event) }
            }
        )
        let composed = AgentWearLinkRuntime(
            device: concreteDevice,
            agent: photoAgent,
            connectionOrder: .deviceFirst,
            diagnostics: diagnostics,
            output: output
        )
        runtime = composed
        device = concreteDevice
        wakeGate = gate
        do {
            try await composed.start()
            // Voice invocations run app-wide (WearablesLink), not per session.
            guard connectionFence.isCurrent(attempt) else {
                await composed.stop()
                clearVoiceReferences()
                return .retry
            }
        } catch {
            await composed.stop()
            clearVoiceReferences()
            if let kind = MetaDATSessionErrorKind(classifying: error) {
                // Not a Gateway fact: never touch the network/gateway hops.
                record("connect failed: session error \(kind.rawValue)")
                handleSessionError(kind)
                return .retry
            }
            let failure = GatewayFailure.classify(error, usedStoredGrant: true)
            record("connect failed: \(failure.rawValue)")
            // A device-side failure (glasses folded mid-connect) is not a
            // network fact; only record Gateway categories we can trust.
            if !(error is AWLError) { failure.apply(to: &signals, at: Date()) }
            if failure == .pairingRevoked { return .needsApproval }
            return .retry
        }

        voiceSession = session
        bindGatewayVoice(session)
        let speech = concreteDevice.capabilities.contains(.speechInput)
        record(speech ? "listening" : "connected without speech")
        wakeAnchor.refresh()
        signals.listening = true
        endWakeBackgroundTask("listening")
        signals.speechReady = speech
        signals.listenFailed = false
        if !speech {
            signals.microphone = await wearables.microphonePermission()
        }
        markGatewayHealthy()
        refreshGlasses()
        // A session that starts while the glasses are off/folded pauses Speech.
        applySpeechPower(wearables.speechDecision, force: true)
        startWatch(session: session, attempt: attempt)
        return .connected
    }

    /// EXPERIMENT: glasses mic over HFP + on-device recognition, no DAT
    /// session. Same agent, gate, echo guard, speech output and follow-up.
    private func connectGlassesMic(session: GatewaySession, agent: OpenClawNativeAgentAdapter, attempt: UInt64) async -> ConnectOutcome {
        let gate = WakeGateBox(phrases: settings.effectiveWakePhrases)
        speaker.gate = gate
        speaker.allowHandsFree = true
        let sink = StreamingSpeechOutput(synthesizer: speaker)
        speechSink = sink
        let log: @Sendable (String) -> Void = { [weak self] line in Task { @MainActor in self?.record(line) } }
        let mic = GlassesMicSpeechAdapter(
            language: Self.speechLanguage,
            contextualPhrases: settings.effectiveWakePhrases,
            log: log
        )
        await mic.setTranscriptGate { [weak self] text in
            let heardAt = Date()
            let result = await gate.evaluate(text)
            await self?.observeTranscript(text, result: result, heardAt: heardAt)
            if case let .forward(request) = result.decision { return request }
            return nil
        }
        let output: @Sendable (InteractionEvent) async -> Void = { [weak self] event in
            await sink.consume(event)
            await self?.observeOutput(event, attempt: attempt)
        }
        // Gateway first: while it is down, a retry fails before the glasses
        // mic touches the audio session (no category flip per retry).
        let composed = AgentWearLinkRuntime(device: mic, agent: agent, connectionOrder: .agentFirst, diagnostics: diagnostics, output: output)
        runtime = composed
        micDevice = mic
        wakeGate = gate
        do {
            try await composed.start()
            guard connectionFence.isCurrent(attempt) else {
                await composed.stop()
                clearVoiceReferences()
                return .retry
            }
        } catch {
            await composed.stop()
            clearVoiceReferences()
            record("glasses-mic connect failed: \(error)")
            return .retry
        }
        voiceSession = session
        bindGatewayVoice(session)
        record("listening (glasses mic, experiment)")
        signals.listening = true
        endWakeBackgroundTask("listening")
        signals.speechReady = true
        signals.listenFailed = false
        markGatewayHealthy()
        refreshGlasses()
        startWatch(session: session, attempt: attempt)
        return .connected
    }

    /// Asks for speech-recognition permission (needed by the glasses-mic
    /// experiment). Call from the foreground.
    func requestSpeechRecognition() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in self?.record("speech recognition authorization \(status.rawValue)") }
        }
        // The glasses mic itself also needs record permission.
        Task { [weak self] in
            let granted = await AVAudioApplication.requestRecordPermission()
            self?.record("microphone record permission \(granted ? "granted" : "denied")")
        }
    }

    /// Watches a live session: a supervisor that stopped for good (e.g. a
    /// revoked grant) never retires the runtime by itself.
    private func startWatch(session: GatewaySession, attempt: UInt64) {
        watchTask?.cancel()
        watchTask = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, !Task.isCancelled, self.connectionFence.ownsRuntime(attempt) else { return }
                let connection = await session.connectionState()
                var failure: GatewayFailure?
                if connection == .ready {
                    do {
                        try await session.health()
                    } catch {
                        failure = GatewayFailure.classify(error, usedStoredGrant: true)
                    }
                }
                guard !Task.isCancelled, self.connectionFence.ownsRuntime(attempt) else { return }
                failures = (failure == nil && connection == .ready) ? 0 : failures + 1
                if failure == nil, connection == .ready { self.markGatewayHealthy() }
                switch VoiceSessionWatch.decide(
                    connection: connection, healthFailure: failure, consecutiveFailures: failures
                ) {
                case .keep:
                    continue
                case .reconnect:
                    self.record("watch: session replaced")
                    await self.disconnectVoice()
                    self.listeningLost("gateway down")
                    self.startRecovery("session watch", immediate: false, restart: true)
                    return
                case .stopNeedsApproval:
                    self.record("watch: approval revoked")
                    self.cancelRecovery()
                    await self.disconnectVoice()
                    GatewayFailure.pairingRevoked.apply(to: &self.signals, at: Date())
                    return
                }
            }
        }
    }

    private func configureDevice(_ device: MetaDATDeviceAdapter, gate: WakeGateBox) async {
        let log: @Sendable (String) -> Void = { [weak self] line in
            Task { @MainActor in self?.record(line) }
        }
        await device.setActivityLogger(log)
        await device.setSessionErrorObserver { [weak self] kind in
            Task { @MainActor in self?.handleSessionError(kind) }
        }
        await device.setTranscriptGate { [weak self] text in
            let heardAt = Date()
            let result = await gate.evaluate(text)
            await self?.observeTranscript(text, result: result, heardAt: heardAt)
            if case let .forward(request) = result.decision { return request }
            return nil
        }
        await device.setGlassesInputHandler { [weak self] isSelect, _ in
            guard isSelect, let self else { return }
            // While a reply plays or is awaited, a double tap stops it.
            if await self.doubleTapStopsReply() { return }
            await gate.arm()
            log("armed by double tap")
            await self.playCue(.listening)
        }
    }

    private func observeTranscript(_ text: String, result: WakeGateBox.Result, heardAt: Date) {
        let decision = result.decision
        // A transcript proves Speech is running.
        signals.speechReady = true
        if result.verdict != .empty, speechRestartingSince != nil {
            speechRestartingSince = nil
            updateRecovery()
        }
        quality.record(result.verdict)
        switch decision {
        case let .forward(request):
            let now = Date()
            latency.requestForwarded(at: now)
            if let unreported = stages.forwarded(finalAt: heardAt, at: now) { reportTurn(unreported) }
            startWaitingCues()
            // Only the length is logged; transcripts never enter the log.
            record("request forwarded (\(request.count) chars)")
        case .armed:
            record("armed by name")
            playCue(.listening)
        case .ignore:
            if result.verdict == .stop { stopReply(.voice) }
        }
        if !settings.setupCompleted, setup.current == .practice {
            practice.transcript = text
            practice.matched = decision != .ignore
        }
    }

    private func observeOutput(_ event: InteractionEvent, attempt: UInt64) {
        let now = Date()
        switch event {
        case let .text(id, _):
            stages.replyText(at: now)
            if let seconds = latency.replyText(replyID: String(describing: id), at: now) {
                settings.lastReplyLatency = seconds
                signals.lastReplyLatency = seconds
            }
            settings.lastReplyAt = now
            signals.lastReplyAt = now
            signals.agentFailing = false
            signals.checkedAt[.agent] = now
            stopWaitingCues()
        case .turnCompleted:
            signals.agentFailing = false
            signals.checkedAt[.agent] = now
            stopWaitingCues()
            if stages.awaitingText {
                // False-trigger proxy: the agent had nothing to say.
                quality.noReply(at: now)
                if let turn = stages.flush() { reportTurn(turn) }
            } else if !speaker.isSpeaking, let turn = stages.flush() {
                // Nothing will play (route guard, empty reply).
                reportTurn(turn)
            }
            // Open the follow-up window once the reply has been spoken (all
            // reply text is queued by now), and only if something was spoken.
            followUp.turnCompleted(followUpEnabled: settings.followUp)
            if pendingMusicWatch != nil { photoTurnReplyDone = true }
            if !speaker.isSpeaking { replySpeechIdle() }
        case let .failed(id, error):
            if id == nil, case .device = error {
                // Core retired the runtime after a terminal device failure.
                stopWaitingCues()
                Task { await retireAfterDeviceLoss(attempt: attempt) }
            } else if id != nil {
                signals.agentFailing = true
                signals.checkedAt[.agent] = now
                record("turn failed")
                pendingMusicWatch = nil
                photoTurnReplyDone = false
                stopWaitingCues()
                if let turn = stages.flush() { reportTurn(turn) }
                playCue(.failed)
            }
        default:
            break
        }
    }

    // MARK: Photo turns ("이거 뭐야?")

    /// Music state around the current photo turn; the reminder is decided
    /// once its reply has finished.
    private var pendingMusicWatch: PhotoMusicWatch?
    private var photoTurnReplyDone = false
    private var musicCheckTask: Task<Void, Never>?
    /// Diagnostics photo test: thumbnail on screen only (never saved or
    /// logged), dropped when the screen goes away.
    @Published private(set) var photoTest: PhotoTestState = .idle

    enum PhotoTestState {
        case idle
        case running(PhotoCaptureMethod)
        case captured(UIImage, PhotoCaptureMethod)
        case failed(PhotoCaptureMethod)
    }

    private static func metaMode(_ method: PhotoCaptureMethod) -> MetaDATSnapshotMode {
        switch method {
        case .streamStill: return .compatibleStreamStill
        case .standalonePhoto: return .experimentalStandalonePhoto
        }
    }

    /// One photo for a visual request. Never changes the audio session
    /// (the DAT session is live); only reads whether other audio plays.
    private func capturePhotoForTurn(_ id: InteractionID) async -> PhotoCaptureOutcome {
        guard let device else { return .unavailable(reason: "no glasses session") }
        guard ThermalWorkPolicy.allowsPhoto(stage: thermalStage.stage) else {
            return .unavailable(reason: "heat")
        }
        let method = settings.photoCaptureMethod
        let watch = PhotoMusicWatch(playingBefore: AVAudioSession.sharedInstance().isOtherAudioPlaying)
        playCue(.shutter)
        do {
            let result = try await device.captureSnapshot(interactionID: id, mode: Self.metaMode(method))
            record(result.timings.logLine)
            if let total = result.timings.totalMilliseconds {
                quality.photoCaptured(seconds: Double(total) / 1000)
            }
            pendingMusicWatch = watch
            photoTurnReplyDone = false
            watchMusicAfterPhoto(watch)
            return .photo(result.image)
        } catch {
            if let partial = await device.lastSnapshotTimings { record(partial.logLine + " (failed)") }
            let reason = Self.photoFailureReason(error)
            record("photo failed [\(method.rawValue)]: \(reason)")
            // A failed capture may still have run the camera and stopped music.
            pendingMusicWatch = watch
            photoTurnReplyDone = false
            watchMusicAfterPhoto(watch)
            return .unavailable(reason: reason)
        }
    }

    /// Stable, text-free failure categories (AWL's own messages only).
    private static func photoFailureReason(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let error = error as? AWLError {
            switch error {
            case let .capabilityUnavailable(message), let .device(message): return message
            case .timeout: return "timeout"
            default: return "error"
            }
        }
        if error is MetaDATPhotoNormalizationError { return "unexpected photo encoding" }
        return "error"
    }

    private func observePhotoTurn(_ event: PhotoTurnEvent) {
        switch event {
        case let .intent(reason):
            record("photo request (\(reason.rawValue))")
        case .sentWithPhoto:
            quality.photoTurn()
            record("request sent with photo")
        case let .sentWithoutPhoto(reason):
            quality.photoFailed()
            record("request sent without photo (\(reason))")
        case .imageRejected:
            quality.photoFailed()
            record("gateway refused the photo; sent without it")
        }
    }

    /// Logs whether other audio (music) still plays ~1 s and ~4 s after the
    /// photo (dat-ios #256: a camera stream may pause it for good).
    private func watchMusicAfterPhoto(_ initial: PhotoMusicWatch) {
        musicCheckTask?.cancel()
        record("music before photo: \(initial.playingBefore ? "playing" : "not playing")")
        musicCheckTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            let one = AVAudioSession.sharedInstance().isOtherAudioPlaying
            self.updateMusicWatch { $0.afterOneSecond = one }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            let four = AVAudioSession.sharedInstance().isOtherAudioPlaying
            var final = initial
            final.afterOneSecond = one
            final.afterFourSeconds = four
            self.updateMusicWatch { $0.afterFourSeconds = four }
            self.record(final.logLine)
        }
    }

    private func updateMusicWatch(_ change: (inout PhotoMusicWatch) -> Void) {
        guard var watch = pendingMusicWatch else { return }
        change(&watch)
        pendingMusicWatch = watch
    }

    /// After a photo turn's reply: one line if the photo stopped the music.
    /// Returns true when the line was queued.
    private func speakMusicReminderIfDue() -> Bool {
        guard photoTurnReplyDone, let watch = pendingMusicWatch else { return false }
        pendingMusicWatch = nil
        photoTurnReplyDone = false
        let playingNow = AVAudioSession.sharedInstance().isOtherAudioPlaying
        guard PhotoMusicPolicy.shouldRemind(
            enabled: settings.photoMusicHint, playingBefore: watch.playingBefore, playingNow: playingNow
        ) else { return false }
        record("music reminder spoken")
        let line = PhotoMusicPolicy.reminder(korean: WakePhrases.prefersKorean)
        Task { await speaker.speak(line) }
        return true
    }

    /// Diagnostics: one photo with `method`, not sent to the agent. Logs
    /// stage timings and music state; the image stays in memory on screen.
    func testPhoto(_ method: PhotoCaptureMethod) async {
        if case .running = photoTest { return }
        guard let device else {
            record("photo test [\(method.rawValue)]: no glasses session")
            photoTest = .failed(method)
            return
        }
        photoTest = .running(method)
        let permission = await wearables.cameraPermission(request: true)
        record("photo test [\(method.rawValue)]: camera permission \(permission)")
        let before = PhotoMusicWatch(playingBefore: AVAudioSession.sharedInstance().isOtherAudioPlaying)
        playCue(.shutter)
        do {
            let result = try await device.captureSnapshot(interactionID: InteractionID(), mode: Self.metaMode(method))
            record("photo test " + result.timings.logLine)
            if let image = UIImage(data: result.image.data) {
                photoTest = .captured(image, method)
            } else {
                photoTest = .failed(method)
            }
        } catch {
            if let partial = await device.lastSnapshotTimings { record("photo test " + partial.logLine + " (failed)") }
            record("photo test [\(method.rawValue)] failed: \(Self.photoFailureReason(error))")
            photoTest = .failed(method)
        }
        // Log only; a test never queues the spoken reminder.
        pendingMusicWatch = nil
        watchMusicAfterPhoto(before)
    }

    func clearPhotoTest() {
        photoTest = .idle
    }

    // MARK: Reply voice

    var voiceOptions: [VoiceOption] { speaker.voiceOptions() }

    /// "미리 듣기": speaks a sample with the chosen voice, through the glasses
    /// when connected, otherwise the iPhone speaker (the user is holding the
    /// phone). Replies themselves never use the speaker.
    func previewVoice() {
        Task { await speaker.speak("안녕하십니까, 주인님. 이 목소리로 답해 드릴게요.", allowPhoneSpeaker: true) }
    }

    // MARK: Audio cues and follow-up

    /// Opens the follow-up window only after a turn that spoke something.
    private var followUp = FollowUpTracker()
    private var thinkingTask: Task<Void, Never>?

    /// Plays an earcon into the glasses only (never the iPhone speaker).
    private func playCue(_ earcon: Earcon) {
        guard settings.audioCues else { return }
        // MODERATE heat: only the accepted/failed cues (optional work off).
        guard ThermalWorkPolicy.allowsEarcon(earcon, stage: thermalStage.stage) else { return }
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType).map(ReplySpeaker.kind)
        guard AudioRoutePolicy.canSpeakAloud(outputs: outputs, allowHandsFree: speaker.allowHandsFree) else { return }
        keepAlive.play(earcon)
    }

    private func startWaitingCues() {
        followUp.requestForwarded()
        waitingSince = Date()
        thinkingTask?.cancel()
        playCue(.accepted)
        guard settings.audioCues else { return }
        let ticks = ThinkingCueSchedule().tickTimes
        thinkingTask = Task { [weak self] in
            var elapsed: TimeInterval = 0
            for tick in ticks {
                try? await Task.sleep(for: .seconds(tick - elapsed))
                elapsed = tick
                guard !Task.isCancelled, let self else { return }
                self.playCue(.thinking)
            }
        }
    }

    private func stopWaitingCues() {
        waitingSince = nil
        thinkingTask?.cancel()
        thinkingTask = nil
    }

    /// A request was forwarded and its reply has not started yet.
    private var waitingSince: Date?

    private var isAwaitingReply: Bool {
        guard let waitingSince else { return false }
        return Date().timeIntervalSince(waitingSince) < ThinkingCueSchedule().maximumWait
    }

    // MARK: Stop ("그만" / double tap)

    /// Double tap: stops a reply that is playing or awaited; otherwise the
    /// caller arms the gate as before.
    private func doubleTapStopsReply() -> Bool {
        guard speaker.isSpeaking || isAwaitingReply else {
            quality.armedByTap()
            return false
        }
        stopReply(.tap)
        return true
    }

    /// Stops the reply: speaker (system and gateway voice), the rest of the
    /// streamed reply, thinking ticks and the echo window. No follow-up
    /// window and no cue: the silence itself is the confirmation, and the
    /// "listening" earcon would wrongly suggest the gate is armed. The agent
    /// run itself is not cancelled (the runtime exposes no per-turn cancel);
    /// its late reply is dropped instead.
    private func stopReply(_ source: StopSource) {
        let awaiting = stages.awaitingText || isAwaitingReply
        quality.stopped(source)
        stopWaitingCues()
        followUp.reset()
        if let turn = stages.flush() { reportTurn(turn) }
        record("reply stopped (\(source.rawValue))")
        pendingMusicWatch = nil
        photoTurnReplyDone = false
        let sink = speechSink
        let gate = wakeGate
        Task {
            await sink?.stopCurrentReply(awaitingReply: awaiting)
            await speaker.stop()
            await gate?.closeEchoWindow()
        }
    }

    // MARK: Quality metrics

    /// Reply audio actually started: completes the turn's latency stages.
    private func replyAudioStarted(_ voice: TurnStages.Voice) {
        guard let turn = stages.audioStarted(voice: voice, at: Date()) else { return }
        reportTurn(turn)
    }

    private func reportTurn(_ turn: TurnStages) {
        quality.turn(turn)
        if turn.voice != nil {
            let total = (turn.finalToForward ?? 0) + (turn.forwardToFirstText ?? 0) + (turn.firstTextToFirstAudio ?? 0)
            lastFirstAudioMilliseconds = Int((total * 1000).rounded())
        }
        record(turn.logLine)
    }

    /// Worn, listening on, no call: the wearer expects the agent to hear.
    private var shouldListenNow: Bool {
        wantsListening && signals.glasses == .connected && signals.speechPause == .listen && callGate.allowsReconnect
            && signals.hold == nil
    }

    /// A voice session is up and Speech is actually running.
    private var listeningUp: Bool {
        signals.listening && signals.speechPause == .listen && speechRestartingSince == nil
    }

    private func listeningLost(_ reason: String) {
        guard !signalsFrozen else { return }
        recovery.lost(reason, shouldListen: shouldListenNow, at: Date())
        updateRecovery()
    }

    private func updateRecovery() {
        guard started, let result = recovery.update(shouldListen: shouldListenNow, listening: listeningUp, at: Date()) else { return }
        record(result.logLine)
    }

    /// Activity-log lines that carry metric events (counts only).
    private func noteMetricLine(_ message: String) {
        if message.hasPrefix("speech stall restart") {
            quality.deafRestart()
            speechRestartingSince = Date()
            listeningLost("speech deaf restart")
        } else if speechRestartingSince != nil, message.hasPrefix("speech "),
                  message.lowercased().contains("started"), !message.contains("restart") {
            speechRestartingSince = nil
            updateRecovery()
        }
    }

    /// The synthesizer has nothing left to say. After a completed turn,
    /// arm the gate so the wearer can continue without the wake phrase.
    private func replySpeechIdle() {
        // The music line goes first; its own idle then opens the follow-up.
        if speakMusicReminderIfDue() { return }
        guard followUp.speechIdle(), let wakeGate else { return }
        Task {
            await wakeGate.arm()
            record("follow-up window open (\(Int(FollowUpWindow.seconds)) s)")
            playCue(.listening)
        }
    }

    private func retireAfterDeviceLoss(attempt: UInt64) async {
        guard connectionFence.ownsRuntime(attempt), runtime != nil, !disconnectInProgress else { return }
        await disconnectVoice()
        record("device session lost")
        // Calls end the DAT session on current firmware (#332).
        listeningLost(callGate.allowsReconnect ? "device session lost" : "call")
        refreshGlasses()
        // The keep-alive keeps running, so this loop survives a locked phone.
        if wantsListening { startRecovery("device session lost", immediate: false, restart: true) }
    }

    private func disconnectVoice() async {
        guard !disconnectInProgress else { return }
        disconnectInProgress = true
        defer { disconnectInProgress = false }
        connectionFence.invalidate()
        watchTask?.cancel()
        watchTask = nil
        if let runtime { await runtime.stop() }
        clearVoiceReferences()
    }

    /// Note: the keep-alive is deliberately NOT stopped here; it follows
    /// whether listening is wanted, not whether a session is up.
    private func clearVoiceReferences() {
        micDevice = nil
        bindGatewayVoice(nil)
        stopWaitingCues()
        followUp.reset()
        runtime = nil
        device = nil
        speechSink = nil
        voiceSession = nil
        wakeGate = nil
        pendingMusicWatch = nil
        photoTurnReplyDone = false
        signals.listening = false
        signals.speechReady = false
    }

    private static var speechLanguage: String {
        let preferred = Locale.preferredLanguages.first ?? "ko-KR"
        return preferred.hasPrefix("ko") ? "ko-KR" : preferred
    }

    private func record(_ message: String) {
        log.append(message)
        if message.hasPrefix("speech stall restart") { speechStallRestartCount += 1 }
        if message.hasPrefix("request forwarded") { turnCount += 1 }
        noteMetricLine(message)
        #if DEBUG
        // Same lines as the diagnostics screen (never transcripts), so a
        // connected Mac can follow them with `devicectl ... --console`.
        print("[AWL] \(message)")
        #endif
    }

    /// QR scanner lifecycle (authorization, running, interruptions) for the
    /// diagnostics log. Never carries the scanned payload.
    func noteCamera(_ event: String) {
        record("camera: \(event)")
    }

    // MARK: DEBUG fixtures

    #if DEBUG
    /// Shown as listening by screenshot fixtures (no real runtime exists).
    private var previewListening = false

    func applyPreview(_ plan: CompanionPreviewFixture.Plan) {
        signalsFrozen = true
        started = true
        settings = plan.settings
        signals = plan.signals
        setup = plan.setup
        metaConfiguration = plan.metaConfiguration
        deviceID = plan.deviceID
        pairing = plan.pairing
        practice = plan.practice
        previewListening = plan.listening
        pendingRequestID = plan.pendingRequestID
        var log = ActivityLog()
        let base = Date().addingTimeInterval(-Double(plan.logLines.count) * 7)
        for (index, line) in plan.logLines.enumerated() {
            log.append(line, at: base.addingTimeInterval(Double(index) * 7))
        }
        self.log = log
        lastCheckAt = signals.checkedAt.values.max()
    }
    #endif
}
