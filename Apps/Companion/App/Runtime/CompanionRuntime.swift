import AgentWearLinkAppleOutput
import AgentWearLinkCore
import AgentWearLinkMetaDATIntegration
import AgentWearLinkOpenClaw
import Foundation
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
    @Published private(set) var signals = ConnectionSignals()
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
    private let lifecycle = MetaDATApplicationLifecycle(initialPhase: .foreground)
    private let diagnostics = AWLDiagnosticRecorder(capacity: 256)
    private let pathMonitor = NWPathMonitor()
    private var pathSatisfied: Bool?
    private var appActive = true

    private var runtime: AgentWearLinkRuntime?
    private var device: MetaDATDeviceAdapter?
    /// Set only after the runtime started, so health checks never use a
    /// session whose dispatcher is not ready yet.
    private var voiceSession: GatewaySession?
    private var voiceConnecting = false
    private var wakeGate: WakeGateBox?
    private var latency = TurnLatencyTracker()
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
        keepAlive.isDATSessionLive = { [weak self] in
            guard let self else { return false }
            return self.runtime != nil || self.voiceConnecting
        }
        speaker.onEvent = { [weak self] line in self?.record(line) }
        speaker.onSilenced = { [weak self] in self?.signals.replyNotSpoken = true }
        speaker.onSpoken = { [weak self] in self?.signals.replyNotSpoken = false }
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
        deviceID = (try? await gatewayLink.deviceID()) ?? ""
        refreshGlasses()
        signals.microphone = await wearables.microphonePermission()

        if startRequest.consume(), settings.setupCompleted, !settings.listenEnabled {
            // A Start Listening intent that arrived before the UI subscribed.
            settings.listenEnabled = true
        }
        if !settings.setupCompleted { await restoreSetupProgress() }
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
                refreshGlasses()
                if wantsListening {
                    // iOS only lets playback start in the foreground.
                    keepAlive.start()
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

    /// "Start listening" App Intent / App Shortcut.
    func startListeningFromIntent() {
        _ = startRequest.consume()
        guard started, settings.setupCompleted else { return }
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
        if wantsListening {
            // May fail in the background; the keep-alive watchdog retries.
            keepAlive.start()
            if restartSession, runtime != nil {
                record("restart: \(reason)")
                await disconnectVoice()
                // No DAT session now: safe to reactivate audio if needed.
                keepAlive.start()
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
        if actions.restartKeepAlive { keepAlive.start() }
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
        if old.effectiveWakePhrases != settings.effectiveWakePhrases, let wakeGate {
            let phrases = settings.effectiveWakePhrases
            Task { await wakeGate.replacePhrases(phrases) }
        }
        let turnOptionsChanged = CompanionTurnOptions.make(from: old) != CompanionTurnOptions.make(from: settings)
            || old.sessionKey != settings.sessionKey
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
                if self.appActive { await self.checkNow() }
            }
        }
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
        let snapshot = wearables.snapshot()
        signals.glasses = snapshot.glasses
        signals.glassesBattery = snapshot.battery
        signals.glassesCharging = snapshot.charging
        signals.checkedAt[.glasses] = Date()
        if !settings.setupCompleted, wearables.isRegistered, setup.current == .metaRegistration {
            setup.complete(.metaRegistration)
        }
        applySpeechPower(wearables.speechDecision)
    }

    /// Stops Speech (the DAT session) when the glasses are taken off,
    /// folded or too hot, and brings it back when they are usable again.
    private func applySpeechPower(_ decision: SpeechPowerPolicy.Decision) {
        let previous = signals.speechPause
        signals.speechPause = decision
        guard decision != previous else { return }
        record("speech power: \(decision)")
        if decision != .listen {
            if runtime != nil { Task { await disconnectVoice() } }
        } else if wantsListening, runtime == nil {
            startRecovery("glasses usable again", immediate: false, restart: true)
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
                // Connected AND worn/unfolded/not too hot.
                await self.wearables.waitForUsableDevice()
                if Task.isCancelled { break }
                if settle {
                    try? await Task.sleep(for: .seconds(RecoveryPolicy.settleDelay))
                }
                settle = true
                guard !Task.isCancelled, self.wantsListening, self.runtime == nil else { break }
                let outcome = await self.connectVoice()
                // Glasses are on but no session came up: say so on Home.
                self.signals.listenFailed = outcome == .retry && self.wearables.hasConnectedDevice
                if outcome != .retry { break }
                let delay = RecoveryPolicy.delay(afterFailedAttempt: attempt)
                attempt += 1
                try? await Task.sleep(for: .seconds(delay))
            }
            // Only the loop that is still current may clear the slot.
            if let self, self.recoveryGeneration == generation { self.recoveryTask = nil }
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
            turnOptions: CompanionTurnOptions.make(from: settings)
        )
        let concreteDevice = MetaDATDeviceAdapter(applicationLifecycle: lifecycle, diagnostics: diagnostics)
        let gate = WakeGateBox(phrases: settings.effectiveWakePhrases)
        speaker.gate = gate
        let sink = AppleSpeechOutput(synthesizer: speaker)
        await configureDevice(concreteDevice, gate: gate)

        let output: @Sendable (InteractionEvent) async -> Void = { [weak self] event in
            await sink.consume(event)
            await self?.observeOutput(event, attempt: attempt)
        }
        // Device first: if the glasses dropped again, fail there without
        // dialling the Gateway.
        let composed = AgentWearLinkRuntime(
            device: concreteDevice,
            agent: agent,
            connectionOrder: .deviceFirst,
            diagnostics: diagnostics,
            output: output
        )
        runtime = composed
        device = concreteDevice
        wakeGate = gate
        do {
            try await composed.start()
            guard connectionFence.isCurrent(attempt) else {
                await composed.stop()
                clearVoiceReferences()
                return .retry
            }
            await concreteDevice.startVoiceInvocationListening()
            guard connectionFence.isCurrent(attempt) else {
                await concreteDevice.stopVoiceInvocationListening()
                await composed.stop()
                clearVoiceReferences()
                return .retry
            }
        } catch {
            await concreteDevice.stopVoiceInvocationListening()
            await composed.stop()
            clearVoiceReferences()
            let failure = GatewayFailure.classify(error, usedStoredGrant: true)
            record("connect failed: \(failure.rawValue)")
            // A device-side failure (glasses folded mid-connect) is not a
            // network fact; only record Gateway categories we can trust.
            if !(error is AWLError) { failure.apply(to: &signals, at: Date()) }
            if failure == .pairingRevoked { return .needsApproval }
            return .retry
        }

        voiceSession = session
        let speech = concreteDevice.capabilities.contains(.speechInput)
        record(speech ? "listening" : "connected without speech")
        signals.listening = true
        signals.speechReady = speech
        signals.listenFailed = false
        if !speech {
            signals.microphone = await wearables.microphonePermission()
        }
        markGatewayHealthy()
        refreshGlasses()
        startWatch(session: session, attempt: attempt)
        return .connected
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
        await device.setTranscriptGate { [weak self] text in
            let decision = await gate.evaluate(text)
            await self?.observeTranscript(text, decision: decision)
            if case let .forward(request) = decision { return request }
            return nil
        }
        await device.setGlassesInputHandler { isSelect, _ in
            guard isSelect else { return }
            await gate.arm()
            log("armed by double tap")
        }
    }

    private func observeTranscript(_ text: String, decision: AWLWakePhraseGate.Decision) {
        // A transcript proves Speech is running.
        signals.speechReady = true
        switch decision {
        case let .forward(request):
            latency.requestForwarded(at: Date())
            // Only the length is logged; transcripts never enter the log.
            record("request forwarded (\(request.count) chars)")
        case .armed:
            record("armed by name")
        case .ignore:
            break
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
            if let seconds = latency.replyText(replyID: String(describing: id), at: now) {
                settings.lastReplyLatency = seconds
                signals.lastReplyLatency = seconds
            }
            settings.lastReplyAt = now
            signals.lastReplyAt = now
            signals.agentFailing = false
            signals.checkedAt[.agent] = now
        case .turnCompleted:
            signals.agentFailing = false
            signals.checkedAt[.agent] = now
        case let .failed(id, error):
            if id == nil, case .device = error {
                // Core retired the runtime after a terminal device failure.
                Task { await retireAfterDeviceLoss(attempt: attempt) }
            } else if id != nil {
                signals.agentFailing = true
                signals.checkedAt[.agent] = now
                record("turn failed")
            }
        default:
            break
        }
    }

    private func retireAfterDeviceLoss(attempt: UInt64) async {
        guard connectionFence.ownsRuntime(attempt), runtime != nil, !disconnectInProgress else { return }
        await disconnectVoice()
        record("device session lost")
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
        if let device { await device.stopVoiceInvocationListening() }
        if let runtime { await runtime.stop() }
        clearVoiceReferences()
    }

    /// Note: the keep-alive is deliberately NOT stopped here; it follows
    /// whether listening is wanted, not whether a session is up.
    private func clearVoiceReferences() {
        runtime = nil
        device = nil
        voiceSession = nil
        wakeGate = nil
        signals.listening = false
        signals.speechReady = false
    }

    private static var speechLanguage: String {
        let preferred = Locale.preferredLanguages.first ?? "ko-KR"
        return preferred.hasPrefix("ko") ? "ko-KR" : preferred
    }

    private func record(_ message: String) {
        log.append(message)
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
