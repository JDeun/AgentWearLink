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
/// notifications. A user turning "안경 호출 받기" off stops recovery.
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
    @Published private(set) var isChecking = false
    @Published private(set) var lastCheckAt: Date?
    @Published private(set) var log = ActivityLog()

    var isListening: Bool { runtime != nil }
    var homeState: HomeViewState {
        HomeViewState(signals: signals, telegramConfigured: settings.isTelegramDeliveryConfigured)
    }

    private let store: CompanionSettingsStore
    private let wearables = WearablesLink()
    private let gatewayLink = GatewayLink()
    private let keepAlive = SilentKeepAlive()
    private let lifecycle = MetaDATApplicationLifecycle(initialPhase: .foreground)
    private let diagnostics = AWLDiagnosticRecorder(capacity: 256)
    private let pathMonitor = NWPathMonitor()
    private var pathSatisfied: Bool?

    private var runtime: AgentWearLinkRuntime?
    private var device: MetaDATDeviceAdapter?
    private var voiceSession: GatewaySession?
    private var wakeGate: WakeGateBox?
    private var latency = TurnLatencyTracker()
    private var connectionFence = AWLConnectionAttemptFence()
    private var disconnectInProgress = false
    private var recoveryTask: Task<Void, Never>?
    private var pairingTask: Task<Void, Never>?
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
    }

    // MARK: Launch

    /// Called once from the app's `.task`.
    func start() async {
        guard !started else { return }
        started = true
        #if DEBUG
        if CompanionPreviewFixture.apply(to: self) { return }
        #endif
        startPathMonitor()
        let configuration = wearables.configure()
        metaConfiguration = configuration
        record("meta \(configuration)")
        wearables.observe { [weak self] in self?.refreshGlasses() }
        deviceID = (try? await gatewayLink.deviceID()) ?? ""
        refreshGlasses()
        signals.microphone = await wearables.microphonePermission()

        if settings.setupCompleted {
            if settings.listenEnabled { scheduleRecovery(reason: "launch", immediate: true) }
        } else {
            await restoreSetupProgress()
        }
        await checkNow()
        startPeriodicChecks()
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        Task {
            if phase == .active {
                await lifecycle.transition(to: .foreground)
                guard started, !signalsFrozen else { return }
                refreshGlasses()
                if settings.setupCompleted, settings.listenEnabled, runtime == nil {
                    scheduleRecovery(reason: "foreground", immediate: true)
                }
                await checkNow()
            } else if phase == .background, runtime == nil {
                // A live voice session is deliberately NOT retired in the
                // background: the wearer talks with the phone locked.
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
        guard settings.setupCompleted else { return }
        if !settings.listenEnabled { settings.listenEnabled = true }
        scheduleRecovery(reason: "start listening intent", immediate: true)
    }

    // MARK: Setup

    private func restoreSetupProgress() async {
        var progress = SetupProgress()
        if wearables.isRegistered { progress.complete(.metaRegistration) }
        if signals.microphone == .granted { progress.complete(.microphone) }
        if let endpoint = try? GatewayAddress.endpoint(fromUserInput: settings.gatewayURL),
           await gatewayLink.hasWriteGrant(for: endpoint) {
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
        if step == .gateway { startPracticeIfPossible() }
    }

    func skipStep(_ step: SetupStep) {
        setup.skip(step)
        if setup.isFinished { finishSetup() }
    }

    func finishSetup() {
        setup = SetupProgress(completed: Set(SetupStep.allCases))
        settings.setupCompleted = true
        practice = PracticeState()
        if settings.listenEnabled { scheduleRecovery(reason: "setup finished", immediate: true) }
        Task { await checkNow() }
    }

    private func startPracticeIfPossible() {
        practice = PracticeState()
        scheduleRecovery(reason: "call practice", immediate: true)
    }

    // MARK: Pairing

    func pair(setupCode raw: String) {
        do {
            let code = try OpenClawSetupCode(raw)
            let endpoint = try GatewayAddress.endpoint(for: code.url)
            runPairing(endpoint: endpoint, credentials: .init(bootstrapToken: code.bootstrapToken))
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
            runPairing(endpoint: endpoint, credentials: .init(token: token.isEmpty ? nil : token))
        } catch GatewayAddressError.insecure {
            pairing = .failed(.insecureAddress)
        } catch {
            pairing = .failed(.invalidAddress)
        }
    }

    func cancelPairing() {
        pairingTask?.cancel()
        pairingTask = nil
        pairing = .idle
    }

    /// Connects, and while the Gateway answers "pairing required" keeps
    /// retrying quietly until the device is approved on the host. The
    /// one-time credential lives only inside this task.
    private func runPairing(endpoint: OpenClawEndpoint, credentials: OpenClawConnectCredentials) {
        pairingTask?.cancel()
        pairing = .connecting
        record("pairing started (\(endpoint.exposure.rawValue))")
        pairingTask = Task { [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(10 * 60)
            while !Task.isCancelled {
                guard Date() < deadline else {
                    self.pairing = .failed(.timedOut)
                    return
                }
                do {
                    let session = try self.gatewayLink.makeSession(
                        endpoint: endpoint, credentials: credentials, diagnostics: self.diagnostics
                    )
                    do {
                        try await session.supervisor.start()
                    } catch {
                        await session.supervisor.stop()
                        throw error
                    }
                    let name = await session.agentName(sessionKey: self.sessionKeyOrNil)
                    await session.supervisor.stop()
                    guard !Task.isCancelled else { return }
                    guard await self.gatewayLink.hasWriteGrant(for: endpoint) else {
                        self.record("pairing finished without a write grant")
                        self.pairing = .failed(.rejected)
                        return
                    }
                    self.settings.gatewayURL = endpoint.gatewayURL.absoluteString
                    if let name, !name.isEmpty { self.settings.agentName = name }
                    self.pairing = .succeeded
                    self.signals.network = .reachable
                    self.signals.gateway = .ok
                    self.record("pairing approved")
                    return
                } catch {
                    let failure = GatewayFailure.classify(error, usedStoredGrant: false)
                    switch failure {
                    case .pairingPending:
                        if self.pairing != .waitingForApproval {
                            self.record("waiting for approval on the host")
                        }
                        self.pairing = .waitingForApproval
                        try? await Task.sleep(for: .seconds(3))
                    case .networkUnreachable:
                        self.record("pairing failed: network")
                        self.pairing = .failed(.network)
                        return
                    case .pairingRevoked:
                        self.pairing = .failed(.rejected)
                        return
                    case .gatewayUnreachable:
                        self.record("pairing failed: gateway")
                        self.pairing = .failed(.gateway)
                        return
                    }
                }
            }
        }
    }

    // MARK: Settings actions

    /// "맥미니 승인만 다시 받기".
    func reapprove() async {
        await stopListening(userInitiated: true)
        if let endpoint = currentEndpoint { await gatewayLink.forgetGrant(for: endpoint) }
        settings.setupCompleted = false
        setup.restartGatewayApproval()
        pairing = .idle
        signals.gateway = .unknown
        record("grant forgotten; approve again")
    }

    /// "모두 지우고 처음부터".
    func resetEverything() async {
        await stopListening(userInitiated: true)
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
        if old.listenEnabled != settings.listenEnabled {
            if settings.listenEnabled {
                if settings.setupCompleted { scheduleRecovery(reason: "listening on", immediate: true) }
            } else {
                Task { await stopListening(userInitiated: true) }
            }
        }
        if old.effectiveWakePhrases != settings.effectiveWakePhrases, let wakeGate {
            let phrases = settings.effectiveWakePhrases
            Task { await wakeGate.replacePhrases(phrases) }
        }
        let turnOptionsChanged = CompanionTurnOptions.make(from: old) != CompanionTurnOptions.make(from: settings)
            || old.sessionKey != settings.sessionKey
        if turnOptionsChanged, runtime != nil {
            Task {
                await stopListening(userInitiated: false)
                scheduleRecovery(reason: "turn options changed", immediate: true)
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

        guard let endpoint = currentEndpoint else {
            lastCheckAt = now
            return
        }
        if pathSatisfied == false {
            GatewayFailure.networkUnreachable.apply(to: &signals, at: now)
            lastCheckAt = now
            return
        }
        do {
            if let voiceSession {
                try await voiceSession.health()
            } else {
                guard await gatewayLink.hasWriteGrant(for: endpoint) else {
                    GatewayFailure.pairingRevoked.apply(to: &signals, at: now)
                    lastCheckAt = now
                    return
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
            signals.network = .reachable
            signals.gateway = .ok
            signals.checkedAt[.network] = Date()
            signals.checkedAt[.gateway] = Date()
        } catch {
            let failure = GatewayFailure.classify(error, usedStoredGrant: true)
            record("check: \(failure.rawValue)")
            failure.apply(to: &signals, at: Date())
        }
        lastCheckAt = Date()
    }

    private func startPeriodicChecks() {
        periodicCheckTask?.cancel()
        periodicCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self, !Task.isCancelled else { return }
                if UIApplication.shared.applicationState == .active { await self.checkNow() }
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
    }

    // MARK: Voice session

    private var currentEndpoint: OpenClawEndpoint? {
        try? GatewayAddress.endpoint(fromUserInput: settings.gatewayURL)
    }

    private var sessionKeyOrNil: String? {
        let key = settings.sessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    /// Waits quietly for the glasses, settles, then connects with the stored
    /// grant, backing off on failures. Never notifies; glasses off or charging
    /// is a normal waiting state.
    private func scheduleRecovery(reason: String, immediate: Bool) {
        guard wearables.isConfigured, recoveryTask == nil, runtime == nil else { return }
        record("recovery: \(reason)")
        recoveryTask = Task { [weak self] in
            var attempt = 0
            var first = immediate
            while !Task.isCancelled {
                guard let self else { return }
                await self.wearables.waitForDevice()
                if Task.isCancelled { return }
                if !first {
                    try? await Task.sleep(for: .seconds(RecoveryPolicy.settleDelay))
                }
                first = false
                guard !Task.isCancelled, self.settings.listenEnabled else { break }
                await self.connectVoice()
                if self.runtime != nil { break }
                let delay = RecoveryPolicy.delay(afterFailedAttempt: attempt)
                attempt += 1
                try? await Task.sleep(for: .seconds(delay))
            }
            self?.recoveryTask = nil
        }
    }

    /// Stops the voice session. A user-initiated stop also ends recovery.
    func stopListening(userInitiated: Bool) async {
        if userInitiated {
            recoveryTask?.cancel()
            recoveryTask = nil
        }
        await disconnectVoice()
    }

    private func connectVoice() async {
        guard runtime == nil, !connectionFence.isStarting, !disconnectInProgress,
              wearables.isRegistered, let endpoint = currentEndpoint else { return }
        guard await gatewayLink.hasWriteGrant(for: endpoint) else {
            signals.gateway = .pairingRevoked
            record("connect skipped: no approved grant")
            return
        }
        guard let attempt = connectionFence.begin() else { return }
        defer { connectionFence.finish(attempt) }

        do {
            let session = try gatewayLink.makeSession(
                endpoint: endpoint, credentials: .init(), diagnostics: diagnostics
            )
            let agent = OpenClawNativeAgentAdapter(
                supervisor: session.supervisor,
                dispatcher: session.dispatcher,
                runClient: OpenClawAgentRunClient(dispatcher: session.dispatcher),
                sessionKey: sessionKeyOrNil,
                turnOptions: CompanionTurnOptions.make(from: settings)
            )
            let concreteDevice = MetaDATDeviceAdapter(
                applicationLifecycle: lifecycle,
                diagnostics: diagnostics
            )
            let gate = WakeGateBox(phrases: settings.effectiveWakePhrases)
            let sink = AppleSpeechOutput(
                synthesizer: EchoGuardSynthesizer(
                    inner: AVSpeechSynthesizerBridge(language: Self.speechLanguage),
                    gate: gate
                )
            )
            await configureDevice(concreteDevice, gate: gate)

            let output: @Sendable (InteractionEvent) async -> Void = { [weak self] event in
                await sink.consume(event)
                await self?.observeOutput(event, attempt: attempt)
            }
            let composed = AgentWearLinkRuntime(
                device: concreteDevice,
                agent: agent,
                connectionOrder: .agentFirst,
                diagnostics: diagnostics,
                output: output
            )
            runtime = composed
            device = concreteDevice
            voiceSession = session
            wakeGate = gate
            do {
                try await composed.start()
                guard connectionFence.isCurrent(attempt) else {
                    await composed.stop()
                    clearVoiceReferences()
                    return
                }
                await concreteDevice.startVoiceInvocationListening()
                guard connectionFence.isCurrent(attempt) else {
                    await concreteDevice.stopVoiceInvocationListening()
                    await composed.stop()
                    clearVoiceReferences()
                    return
                }
                let speech = concreteDevice.capabilities.contains(.speechInput)
                record(speech ? "listening" : "connected without speech")
                if !speech, signals.microphone != .granted {
                    signals.microphone = await wearables.microphonePermission()
                }
                if keepAlive.start() { record("keep-alive on") }
                signals.listening = true
                signals.network = .reachable
                signals.gateway = .ok
                signals.checkedAt[.network] = Date()
                signals.checkedAt[.gateway] = Date()
                refreshGlasses()
            } catch {
                await concreteDevice.stopVoiceInvocationListening()
                await composed.stop()
                clearVoiceReferences()
                let failure = GatewayFailure.classify(error, usedStoredGrant: true)
                record("connect failed: \(failure.rawValue)")
                // A device-side failure (glasses folded mid-connect) is not a
                // network fact; only record Gateway categories we can trust.
                if !(error is AWLError) { failure.apply(to: &signals, at: Date()) }
            }
        } catch {
            record("connect failed: invalid endpoint")
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
        if settings.listenEnabled { scheduleRecovery(reason: "device session lost", immediate: false) }
    }

    private func disconnectVoice() async {
        guard !disconnectInProgress else { return }
        disconnectInProgress = true
        defer { disconnectInProgress = false }
        connectionFence.invalidate()
        if let device { await device.stopVoiceInvocationListening() }
        if let runtime { await runtime.stop() }
        clearVoiceReferences()
    }

    private func clearVoiceReferences() {
        keepAlive.stop()
        runtime = nil
        device = nil
        voiceSession = nil
        wakeGate = nil
        signals.listening = false
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
    func applyPreview(signals: ConnectionSignals, settings: CompanionSettings, setup: SetupProgress,
                      metaConfiguration: WearablesLink.Configuration?, deviceID: String) {
        signalsFrozen = true
        started = true
        self.settings = settings
        self.signals = signals
        self.setup = setup
        self.metaConfiguration = metaConfiguration
        self.deviceID = deviceID
        lastCheckAt = signals.checkedAt.values.max()
    }
    #endif
}
