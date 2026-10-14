import AgentWearLinkAppleOutput
import AgentWearLinkCore
import AgentWearLinkMetaDATIntegration
import AgentWearLinkOpenClaw
import AVFoundation
import Foundation
import MWDATCore
import SwiftUI
import UIKit

/// Human-operated iOS reference composition. Neither test fixtures nor a
/// production Mac mini hostname, pairing identity, token or session key are
/// hardcoded into the application. Use the Meta test host's app identifier
/// and callback registration settings for the intended deployment.
@MainActor
final class AWLReferenceRuntimeHost: ObservableObject {
    @Published private(set) var status = "disconnected"
    @Published private(set) var gatewayHealthStatus = "gateway-not-checked"
    /// EXPERIMENT (locked-phone voice): timestamped phase/heartbeat log so a
    /// physical test can show whether iOS kept the process running.
    @Published private(set) var lockedExperimentLog: [String] = []
    /// A: do not retire the DAT session when the app leaves the foreground.
    var experimentKeepSessionInBackground = false
    /// B: also hold an active playAndRecord AVAudioSession (needs the
    /// `audio` UIBackgroundModes entry on this experiment branch).
    var experimentHoldAudioSession = false
    private var experimentHeartbeat: Task<Void, Never>?
    private let keepAlive = AWLSilentKeepAlive()
    private let speaker = AWLReplySpeaker(language: "ko-KR")
    private var audioHooksInstalled = false
    /// EXPERIMENT E: reply ducking variants (default off).
    var experimentReplyDucking: AWLReplyDuckingMode = .off {
        didSet { speaker.duckingMode = experimentReplyDucking }
    }
    private var speechPowerTask: Task<Void, Never>?
    private let calls = AWLCallMonitor()
    private var callActive = false
    /// Silent self-recovery (no notifications): after an unexpected loss the
    /// host waits for the glasses to be available again and reconnects with
    /// the stored device grant, backing off on gateway failures.
    var autoRecover = false
    private var lastConnectRequest: AWLConnectRequest?
    private var recoveryTask: Task<Void, Never>?
    static let recoveryBackoff: [Duration] = [.seconds(5), .seconds(10), .seconds(30), .seconds(60)]
    /// C: comma-separated wake phrases; empty forwards every final transcript.
    var experimentWakePhrases = ""

    private let lifecycle = MetaDATApplicationLifecycle(initialPhase: .foreground)
    private let diagnostics = AWLDiagnosticRecorder(capacity: 256)
    private var runtime: AgentWearLinkRuntime? {
        // A foreground-only voice session dies when auto-lock suspends the
        // app, so keep the screen awake exactly while a runtime is live.
        didSet { UIApplication.shared.isIdleTimerDisabled = runtime != nil }
    }
    private var device: MetaDATDeviceAdapter?
    private var visionAgent: OpenClawNativeAgentAdapter?
    private var outputSink: AWLStreamingSpeechOutput?
    private var visionTask: Task<Void, Never>?
    private var configured = false
    private var gatewayHealthInProgress = false
    private var connectionFence = AWLConnectionAttemptFence()
    private var disconnectInProgress = false

    /// A deliberate local user gesture copies only typed and bounded
    /// diagnostic evidence; no transport token, text or raw correlation UUID.
    func copySanitizedDiagnostics() {
        do {
            UIPasteboard.general.string = try AWLDiagnosticEvidence.export(
                from: diagnostics,
                maximumEvents: 128
            )
            status = "sanitized-diagnostics-copied"
        } catch {
            status = "diagnostic-export-failed"
        }
    }

    /// Read-only preflight deliberately has no Meta DAT, DeviceSession, camera
    /// or full AgentWearLinkRuntime dependency. Validate iPhone -> Tailnet ->
    /// Mac mini Gateway first, with an independently pairable read-only identity.
    /// The upstream health payload and error descriptions are never surfaced.
    func checkReadOnlyGatewayHealth(hostname: String, token: String) async {
        guard !gatewayHealthInProgress else { return }
        gatewayHealthInProgress = true
        defer { gatewayHealthInProgress = false }

        // An empty token means "reconnect with the device grant this identity was
        // issued on approval" (stored in the iOS Keychain under the service below).
        // That is how #117's persisted-credential reuse is proven on a real
        // iPhone. Without a stored grant the Gateway rejects the handshake and
        // the state reports token-required instead of a generic failure.
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let usesStoredGrant = trimmedToken.isEmpty
        gatewayHealthStatus = "gateway-health-checking"
        do {
            let endpoint = try OpenClawEndpoint.tailnetServe(
                hostname: hostname.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            let socket = try URLSessionOpenClawWebSocket(endpoint: endpoint)
            let state = OpenClawGatewayState()
            let profile = OpenClawValidationProfile.readOnly
            // Do not share pairing grants or device identity with the
            // mutating reference runtime, or the command-line probes.
            let service = "dev.agentwearlink.openclaw.ios-health-probe"
            let assembler = OpenClawConnectAssembler(
                identityManager: .init(
                    store: KeychainOpenClawDeviceIdentityStore(service: service)
                ),
                credentialStore: KeychainOpenClawDeviceCredentialStore(
                    service: service
                ),
                gatewayNamespace: endpoint.credentialNamespace,
                bootstrapHandoffPersistenceAllowed:
                    endpoint.allowsBootstrapHandoffPersistence
            )
            let connection = OpenClawGatewayConnection(
                socket: socket,
                assembler: assembler,
                state: state
            )
            let dispatcher = OpenClawRPCDispatcher(socket: socket, state: state)
            let supervisor = OpenClawGatewaySupervisor(
                connection: connection,
                dispatcher: dispatcher,
                state: state,
                socket: socket,
                appVersion: "0.1.0-ios-health-probe",
                scopes: profile.scopes,
                credentials: .init(token: usesStoredGrant ? nil : trimmedToken),
                clientIdentity: profile.clientIdentity,
                diagnostics: diagnostics
            )

            do {
                try await supervisor.start()
                do {
                    let response = try await dispatcher.request(
                        method: "health",
                        params: AWLReadOnlyHealthParams()
                    )
                    gatewayHealthStatus = response.ok
                        ? "gateway-health-ok"
                        : "gateway-health-failed"
                } catch {
                    gatewayHealthStatus = "gateway-health-failed"
                }
                await supervisor.stop()
            } catch OpenClawHandshakeError.pairingRequired(_) {
                await supervisor.stop()
                gatewayHealthStatus = "gateway-health-pairing-required"
            } catch _ where usesStoredGrant {
                await supervisor.stop()
                gatewayHealthStatus = "gateway-health-token-required"
            } catch {
                await supervisor.stop()
                gatewayHealthStatus = "gateway-health-failed"
            }
        } catch {
            gatewayHealthStatus = "gateway-health-invalid-private-endpoint"
        }
    }

    func configureWearables() async {
        guard !configured else { return }
        // Fail before SDK initialization with test-only placeholder settings.
        // No client token or other registration detail is sent to diagnostics.
        //
        // TeamID and the callback scheme are always required. MetaAppID and
        // ClientToken are only needed outside Meta AI Developer Mode: Meta's
        // CameraAccess sample states "Developer Mode needs no credentials; for
        // other release channels, set META_APP_ID and CLIENT_TOKEN". Empty values
        // therefore mean Developer Mode registration; unexpanded build settings
        // and the CI placeholder "0" are still rejected.
        guard let registration = Bundle.main.object(forInfoDictionaryKey: "MWDAT")
                as? [String: Any],
              Self.isOptionalCredential(registration["MetaAppID"]),
              Self.isOptionalCredential(registration["ClientToken"]),
              let teamID = registration["TeamID"] as? String,
              !teamID.isEmpty, !teamID.contains("$("),
              let link = registration["AppLinkURLScheme"] as? String,
              link.contains("://"), !link.contains("$(") else {
            status = "meta-local-provisioning-required"
            return
        }
        do {
            try Wearables.configure()
            configured = true
        } catch {
            // The local operator can inspect native Meta registration
            // configuration; never embed SDK errors in exported diagnostics.
            status = "meta-configuration-failed"
        }
    }

    /// Absent or empty: Developer Mode. Present: must be a real expanded value.
    static func isOptionalCredential(_ value: Any?) -> Bool {
        guard let value else { return true }
        guard let string = value as? String else { return false }
        if string.isEmpty { return true }
        return string != "0" && !string.contains("$(")
    }

    /// Ask the wearer, through Meta AI, for a glasses permission. DAT Speech and
    /// camera snapshots only check status; nothing in the reference host used to
    /// request it, so on a real device Speech stayed silently unavailable
    /// (2026-10-13). Meta's guidance: check silently first, and request only after an
    /// explicit user action, because the request switches to the Meta AI app.
    func requestGlassesPermission(_ permission: Permission) async {
        guard configured else {
            status = "meta-not-configured"
            return
        }
        let name = permission == .microphone ? "microphone" : "camera"
        do {
            if try await Wearables.shared.checkPermissionStatus(permission) == .granted {
                status = "meta-\(name)-permission-granted"
                return
            }
            let result = try await Wearables.shared.requestPermission(permission)
            status = result == .granted
                ? "meta-\(name)-permission-granted"
                : "meta-\(name)-permission-denied"
        } catch {
            status = "meta-\(name)-permission-request-failed"
        }
    }

    func startRegistration() async {
        guard configured else {
            status = "meta-not-configured"
            return
        }
        do {
            try await MetaDATRegistration().start()
            status = "meta-registration-requested"
        } catch {
            status = "meta-registration-failed"
        }
    }

    func handleMetaCallback(_ url: URL) async {
        guard configured else { return }
        do {
            _ = try await MetaDATRegistration().handleCallback(url)
            status = "meta-callback-received"
        } catch {
            status = "meta-callback-failed"
        }
    }

    func applicationPhase(_ phase: MetaDATApplicationPhase) async {
        if phase == .background {
            visionTask?.cancel()
        }
        if runtime != nil, experimentKeepSessionInBackground {
            // EXPERIMENT A: leave the DAT session alone; only record the phase.
            logExperiment("phase \(phase == .background ? "background" : "foreground") (session kept)")
            return
        }
        await lifecycle.transition(to: phase)
    }

    private func logExperiment(_ line: String) {
        let stamp = Date.now.formatted(date: .omitted, time: .standard)
        lockedExperimentLog.append("\(stamp) \(line)")
        if lockedExperimentLog.count > 200 {
            lockedExperimentLog.removeFirst(lockedExperimentLog.count - 200)
        }
    }

    private func startLockedExperimentIfEnabled() {
        guard experimentKeepSessionInBackground || experimentHoldAudioSession else { return }
        logExperiment("experiment start A=\(experimentKeepSessionInBackground) B=\(experimentHoldAudioSession)")
        if experimentHoldAudioSession {
            // Measured locked-phone keep-alive (.playback/.default/
            // .mixWithOthers, zero-writing source node, 3 s watchdog). It
            // also reports interruptions and media resets for recovery.
            keepAlive.start()
        }
        guard experimentHeartbeat == nil else { return }
        experimentHeartbeat = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self, !Task.isCancelled else { return }
                let state = UIApplication.shared.applicationState
                self.logExperiment("alive \(state == .active ? "active" : state == .background ? "background" : "inactive")")
            }
        }
    }

    private func stopLockedExperiment() {
        // The keep-alive deliberately survives a lost session: iOS suspends
        // a locked app ~2 s after audio stops and refuses to restart playback
        // from the background, so recovery could never run. Only the user's
        // own Disconnect stops it (stopKeepAlive()).
        if !lockedExperimentLog.isEmpty { logExperiment("session stop (keep-alive \(keepAlive.isRunning ? "kept" : "off"))") }
    }

    private func stopKeepAlive() {
        experimentHeartbeat?.cancel()
        experimentHeartbeat = nil
        keepAlive.stop()
    }

    private func installAudioHooks() {
        guard !audioHooksInstalled else { return }
        audioHooksInstalled = true
        keepAlive.onLog = { [weak self] line in self?.logExperiment(line) }
        keepAlive.onEvent = { [weak self] event in self?.handleAudioEvent(event) }
        speaker.onLog = { [weak self] line in self?.logExperiment(line) }
        speaker.setDucking = { [weak self] on in self?.keepAlive.setExperimentalDucking(on) }
        callActive = calls.isCallActive
        calls.onChange = { [weak self] active in
            Task { @MainActor in self?.callsChanged(active) }
        }
        keepAlive.isDATSessionLive = { [weak self] in
            guard let self else { return false }
            return self.runtime != nil || self.connectionFence.isStarting
        }
    }

    /// A phone call ends the DAT session on current firmware (#332): after
    /// an interruption ends or media services reset, rebuild it now rather
    /// than waiting for the 5/10/30/60 s backoff.
    private func handleAudioEvent(_ event: AWLSilentKeepAlive.Event) {
        if event == .mediaServicesReset { speaker.recreate() }
        guard event != .routeChanged, autoRecover, lastConnectRequest != nil else { return }
        let reason = event == .interruptionEnded ? "audio interruption ended" : "media services reset"
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.recoveryTask?.cancel()
            self.recoveryTask = nil
            if self.runtime != nil {
                await self.disconnect()
            }
            // No DAT session now: the only safe moment to reactivate audio.
            if self.experimentHoldAudioSession { self.keepAlive.start() }
            self.scheduleRecoveryIfWanted(reason: reason)
        }
    }

    func connect(
        hostname: String,
        token: String,
        sessionKey: String,
        enableVision: Bool,
        experimentalStandalonePhoto: Bool = false,
        voiceOnly: Bool = false,
        voiceWake: Bool = false,
        turnOptions: OpenClawAgentTurnOptions = AWLReferenceTurnOptions.make()
    ) async {
        #if !DEBUG
        // Pinned DAT 1.0.0 experimental Camera.photo is not publishable.
        guard !experimentalStandalonePhoto else {
            status = "experimental-photo-unavailable-in-release"
            return
        }
        #endif
        guard !(voiceOnly && voiceWake) else {
            status = "invalid-voice-mode"
            return
        }
        guard !connectionFence.isStarting, !disconnectInProgress else {
            status = "connection-in-progress"
            return
        }
        guard runtime == nil else {
            status = "already-connected"
            return
        }
        guard configured else {
            status = "meta-not-configured"
            return
        }
        // A deliberate user gesture can reuse a previously approved,
        // endpoint-scoped device grant instead of entering a shared bearer
        // token again. Never infer authorization merely from an old identity.
        let suppliedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let attempt = connectionFence.begin() else {
            status = "connection-in-progress"
            return
        }
        defer { connectionFence.finish(attempt) }

        status = "connecting"
        do {
            // Require an explicit private TLS Tailnet Serve endpoint rather
            // than an arbitrary public URL or plaintext remote gateway.
            let endpoint = try OpenClawEndpoint.tailnetServe(
                hostname: hostname.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            let socket = try URLSessionOpenClawWebSocket(endpoint: endpoint)
            let state = OpenClawGatewayState()
            let service = "dev.agentwearlink.openclaw.reference-host"
            let identityStore = KeychainOpenClawDeviceIdentityStore(service: service)
            let credentialStore = KeychainOpenClawDeviceCredentialStore(service: service)

            if suppliedToken.isEmpty {
                // First-time pairing still requires explicit credentials.
                // A grant in a different Gateway namespace, a revoked grant,
                // or a read-only grant must never authorize this write-capable
                // runtime. Checking Keychain does not start a network session.
                let scopedStore = GatewayScopedOpenClawDeviceCredentialStore(
                    base: credentialStore,
                    namespace: endpoint.credentialNamespace
                )
                let authorized: Bool
                do {
                    if let identity = try await identityStore.load(),
                       let grant = try await scopedStore.load(
                           deviceID: identity.deviceID,
                           role: "operator"
                       ) {
                        authorized = OpenClawStoredGrantAdmission
                            .permitsWriteRuntime(grant)
                    } else {
                        authorized = false
                    }
                } catch {
                    authorized = false
                }
                guard authorized else {
                    status = "gateway-token-or-approved-grant-required"
                    return
                }
            }

            let assembler = OpenClawConnectAssembler(
                identityManager: .init(store: identityStore),
                credentialStore: credentialStore,
                gatewayNamespace: endpoint.credentialNamespace,
                bootstrapHandoffPersistenceAllowed: endpoint.allowsBootstrapHandoffPersistence
            )
            let connection = OpenClawGatewayConnection(
                socket: socket,
                assembler: assembler,
                state: state
            )
            let dispatcher = OpenClawRPCDispatcher(socket: socket, state: state)
            let supervisor = OpenClawGatewaySupervisor(
                connection: connection,
                dispatcher: dispatcher,
                state: state,
                socket: socket,
                appVersion: "0.1.0-reference-host",
                scopes: ["operator.read", "operator.write"],
                credentials: .init(
                    token: suppliedToken.isEmpty ? nil : suppliedToken
                ),
                clientIdentity: .backend,
                diagnostics: diagnostics
            )
            let agent = OpenClawNativeAgentAdapter(
                supervisor: supervisor,
                dispatcher: dispatcher,
                runClient: OpenClawAgentRunClient(dispatcher: dispatcher),
                sessionKey: sessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty ? nil : sessionKey,
                supportsVisionInput: enableVision,
                turnOptions: turnOptions
            )
            let concreteDevice = MetaDATDeviceAdapter(
                snapshotMode: experimentalStandalonePhoto
                    ? .experimentalStandalonePhoto : .compatibleStreamStill,
                applicationLifecycle: lifecycle,
                diagnostics: diagnostics
            )
            let phrases = experimentWakePhrases
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let wakeGate = AWLWakeGateBox(gate: AWLWakePhraseGate(wakePhrases: phrases))
            installAudioHooks()
            speaker.gate = wakeGate
            // Route guard, reply ducking and an echo window that ends on the
            // synthesizer's real didFinish (+ tail).
            // Sentence-by-sentence as text streams in; control lines dropped.
            let sink = AWLStreamingSpeechOutput(synthesizer: speaker)
            let log: @Sendable (String) -> Void = { [weak self] line in
                Task { @MainActor in self?.logExperiment(line) }
            }
            await concreteDevice.setActivityLogger(log)
            if !phrases.isEmpty {
                log("wake phrases: \(phrases.joined(separator: " / "))")
                await concreteDevice.setTranscriptGate { text in
                    let decision = await wakeGate.evaluate(text)
                    switch decision {
                    case let .forward(request):
                        log("→ send: \(request)")
                        return request
                    case .armed:
                        log("armed by name: \(text)")
                        return nil
                    case .ignore:
                        log("ignored: \(text)")
                        return nil
                    }
                }
            }
            await concreteDevice.setGlassesInputHandler { isSelect, _ in
                guard isSelect else { return }
                await wakeGate.arm()
                log("armed by double tap")
            }
            // No camera/media DeviceSession is created in voice-only mode.
            // Core still owns a production agent, output and event subscription.
            let runtimeDevice: any DeviceAdapter
            if voiceWake {
                runtimeDevice = MetaDATVoiceWakeDeviceAdapter(vendor: concreteDevice)
            } else if voiceOnly {
                runtimeDevice = MetaDATVoiceOnlyDeviceAdapter(vendor: concreteDevice)
            } else {
                runtimeDevice = concreteDevice
            }
            // Core may autonomously retire a runtime after a terminal
            // device/session failure. Route its normalized failure to the
            // host without performing recursive stop() inside the forwarding
            // task that is reporting the failure.
            let output: @Sendable (InteractionEvent) async -> Void = { [weak self] event in
                await sink.consume(event)
                if case let .failed(id, error) = event,
                   id == nil, case .device = error {
                    Task { @MainActor [weak self] in
                        await self?.retireUnexpectedRuntimeFailure(attempt: attempt)
                    }
                }
            }
            let composed = AgentWearLinkRuntime(
                device: runtimeDevice,
                agent: agent,
                // An incoming Meta AI LaunchApp acknowledgement must not wait
                // for slow Tailnet/Gateway connect and pairing. Subscribe first
                // (Core already does), start the independent wearable listener,
                // then connect the agent. Media mode retains agent-first.
                connectionOrder: (voiceWake || voiceOnly) ? .deviceFirst : .agentFirst,
                diagnostics: diagnostics,
                output: output
            )

            // dat-ios #292: activate audio BEFORE the DAT session exists and
            // never reconfigure it while one is live.
            if experimentHoldAudioSession {
                installAudioHooks()
                keepAlive.start()
            }

            // Core itself first subscribes to device.events() before connecting
            // either transport, so no device event is lost during connect.
            runtime = composed
            device = concreteDevice
            // These projections do not implement SnapshotCapturingDevice.
            // Do not enable an explicit camera request from a voice host.
            visionAgent = (voiceOnly || voiceWake) ? nil : agent
            outputSink = sink
            do {
                try await composed.start()

                // A disconnect can arrive while Core is suspended in Meta or
                // Gateway startup. Its generation fence wins over a late
                // successful start: never resurrect an already retired host.
                guard connectionFence.isCurrent(attempt) else {
                    await concreteDevice.stopVoiceInvocationListening()
                    await composed.stop()
                    clearRuntimeReferences()
                    return
                }

                // In media mode, start the independent listener only after the
                // media runtime is ready. Voice-only DeviceAdapter.connect()
                // already started it without touching DeviceSession.
                if !voiceOnly && !voiceWake {
                    await concreteDevice.startVoiceInvocationListening()
                }
                guard connectionFence.isCurrent(attempt) else {
                    await concreteDevice.stopVoiceInvocationListening()
                    await composed.stop()
                    clearRuntimeReferences()
                    return
                }
                startLockedExperimentIfEnabled()
                startSpeechPowerWatch()
                lastConnectRequest = AWLConnectRequest(
                    hostname: hostname,
                    sessionKey: sessionKey,
                    enableVision: enableVision,
                    experimentalStandalonePhoto: experimentalStandalonePhoto,
                    voiceOnly: voiceOnly,
                    voiceWake: voiceWake,
                    turnOptions: turnOptions
                )
                // Channel registration may still be pending. This is not a
                // claim that physical Hey Meta or locked-phone launch works.
                if voiceWake {
                    status = "voice-wake-runtime-started"
                } else {
                    // DAT Speech is optional at startup (a missing microphone
                    // permission must not block camera snapshots), so a bare
                    // "connected" hid that nothing would ever hear the wearer.
                    if voiceOnly {
                        status = "voice-only-runtime-started"
                    } else {
                        status = concreteDevice.capabilities.contains(.speechInput)
                            ? "connected"
                            : "connected-without-speech"
                    }
                }
            } catch {
                await concreteDevice.stopVoiceInvocationListening()
                await composed.stop()
                clearRuntimeReferences()
                if connectionFence.isCurrent(attempt) {
                    status = "connection-failed"
                }
            }
        } catch {
            if connectionFence.isCurrent(attempt) {
                status = "invalid-private-gateway-config"
            }
        }
    }

    /// A terminal global device error is the one case where Core stops
    /// itself without the user pressing Disconnect. It must not strand stale
    /// host references or a misleading "connected" state.
    private func retireUnexpectedRuntimeFailure(attempt: UInt64) async {
        // isCurrent(attempt) only remains true during startup. Long-lived
        // runtime callbacks use the durable generation fence instead.
        guard connectionFence.ownsRuntime(attempt),
              runtime != nil,
              !disconnectInProgress else { return }
        // This starts in a separate MainActor task: runtime.forwardingDid-
        // ReceiveGlobalFailure can finish its own teardown independently.
        await disconnect()
        // A new connect cannot start while disconnectInProgress owns cleanup.
        status = "device-session-lost"
        scheduleRecoveryIfWanted(reason: "device session lost")
    }

    /// The user's own Disconnect: stop and do not recover.
    func userDisconnect() async {
        speechPowerTask?.cancel()
        speechPowerTask = nil
        recoveryTask?.cancel()
        recoveryTask = nil
        lastConnectRequest = nil
        await disconnect()
        stopKeepAlive()
    }

    /// Reconnect with the last settings and the stored grant (no token).
    func reconnectStored(reason: String) async {
        guard runtime == nil, let request = lastConnectRequest ?? storedConnectRequest() else { return }
        logExperiment("reconnect: \(reason)")
        await connect(
            hostname: request.hostname,
            token: "",
            sessionKey: request.sessionKey,
            enableVision: request.enableVision,
            experimentalStandalonePhoto: request.experimentalStandalonePhoto,
            voiceOnly: request.voiceOnly,
            voiceWake: request.voiceWake,
            turnOptions: request.turnOptions
        )
    }

    /// Launch-time / App Intent source of settings when nothing ran yet.
    var storedConnectRequest: () -> AWLConnectRequest? = { nil }

    private func scheduleRecoveryIfWanted(reason: String) {
        guard autoRecover, lastConnectRequest != nil, recoveryTask == nil else { return }
        logExperiment("recovery scheduled: \(reason)")
        recoveryTask = Task { @MainActor [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                // Glasses folded, in the case or charging: wait quietly until
                // DAT reports a device again (first value arrives at once).
                // Paired-but-folded glasses are still listed, so wait for a
                // device whose link is actually connected.
                while !Task.isCancelled {
                    let wearables = Wearables.shared
                    let connected = wearables.devices.contains {
                        wearables.deviceForIdentifier($0)?.linkState == .connected
                    }
                    // Speech pause/resume handles doff/fold; no reconnects
                    // during a call (#332).
                    if connected, !(self?.callActive ?? false) { break }
                    try? await Task.sleep(for: .seconds(2))
                }
                if Task.isCancelled { return }
                // A new session too soon after a stop fails (dat-ios #231).
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                await self.reconnectStored(reason: "recovery attempt \(attempt + 1)")
                if self.runtime != nil {
                    self.logExperiment("recovered")
                    self.recoveryTask = nil
                    return
                }
                let delay = Self.recoveryBackoff[min(attempt, Self.recoveryBackoff.count - 1)]
                attempt += 1
                try? await Task.sleep(for: delay)
            }
        }
    }

    /// Why Speech should be off right now, or nil to listen. Unknown states
    /// never pause; heat sheds first, then folded, then taken off.
    static func speechPauseReason() -> String? {
        let wearables = Wearables.shared
        guard let device = wearables.devices
            .compactMap({ wearables.deviceForIdentifier($0) })
            .first(where: { $0.linkState == .connected }) else { return nil }
        switch device.thermalLevel {
        case .severe, .critical, .emergency, .shutdown: return "glasses too hot (\(device.thermalLevel))"
        default: break
        }
        if device.hingeState == .closed { return "glasses folded" }
        if device.donState == .doffed { return "glasses taken off" }
        return nil
    }

    /// Pauses DAT Speech when the glasses are taken off, folded or too hot
    /// and resumes it when usable again, KEEPING the DAT session: a session
    /// ended by a doff/fold can refuse new starts until a power cycle
    /// (dat-ios #292). Only a real link drop / session stop tears down.
    private func startSpeechPowerWatch() {
        speechPowerTask?.cancel()
        speechPowerTask = Task { @MainActor [weak self] in
            var paused = false
            while !Task.isCancelled {
                guard let self, self.runtime != nil, let device = self.device else { return }
                let reason = Self.speechPauseReason()
                if let reason, !paused {
                    paused = true
                    self.logExperiment("speech paused: \(reason)")
                    await device.pauseSpeech()
                } else if reason == nil, paused {
                    paused = false
                    self.logExperiment("speech resumed")
                    await device.resumeSpeech()
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func callsChanged(_ active: Bool) {
        let wasActive = callActive
        callActive = active
        if active, !wasActive { logExperiment("call started: reconnects paused") }
        guard !active, wasActive else { return }
        logExperiment("last call ended: recovering")
        guard autoRecover, lastConnectRequest != nil else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.recoveryTask?.cancel()
            self.recoveryTask = nil
            if self.runtime != nil { await self.disconnect() }
            if self.experimentHoldAudioSession { self.keepAlive.start() }
            self.scheduleRecoveryIfWanted(reason: "call ended")
        }
    }

    private func clearRuntimeReferences() {
        stopLockedExperiment()
        runtime = nil
        device = nil
        visionAgent = nil
        outputSink = nil
    }

    /// Explicit one-shot photo flow, never invoked by background/session
    /// lifecycle changes or implicit voice events. It shares the exact agent
    /// and output sink used by the connected text runtime.
    func captureAndAsk(prompt: String) async {
        guard visionTask == nil else {
            status = "photo-already-running"
            return
        }
        guard runtime != nil,
              let device, let visionAgent, let outputSink else {
            status = "not-connected"
            return
        }
        guard visionAgent.supportsVisionInput else {
            status = "vision-not-enabled"
            return
        }
        let question = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else {
            status = "photo-prompt-required"
            return
        }

        let id = InteractionID()
        let coordinator = VisionCoordinator(device: device, agent: visionAgent)
        status = "capturing-photo"
        visionTask = Task { [weak self] in
            do {
                let responses = try await coordinator.responses(
                    interactionID: id,
                    prompt: question
                )
                for try await response in responses {
                    try Task.checkCancellation()
                    await outputSink.consume(response)
                }
                if !Task.isCancelled {
                    self?.status = "photo-completed"
                }
            } catch is CancellationError {
                await outputSink.interrupt(interactionID: id)
            } catch {
                await outputSink.consume(
                    AgentResponse.failed(
                        id,
                        .agent("Explicit image request failed")
                    )
                )
                self?.status = "photo-failed"
            }
            self?.visionTask = nil
        }
    }

    func disconnect() async {
        guard !disconnectInProgress else { return }
        disconnectInProgress = true
        defer { disconnectInProgress = false }
        // Invalidate suspended connect() before the first asynchronous stop.
        connectionFence.invalidate()
        status = "disconnecting"
        let oldVisionTask = visionTask
        oldVisionTask?.cancel()
        await oldVisionTask?.value
        visionTask = nil
        if let device {
            await device.stopVoiceInvocationListening()
        }
        if let runtime {
            await runtime.stop()
        }
        clearRuntimeReferences()
        status = "disconnected"
    }
}

private struct AWLReadOnlyHealthParams: Encodable, Sendable {}

/// Per-turn options the reference host sends with every glasses turn.
enum AWLReferenceTurnOptions {
    /// Lets Gateway plugins recognise a spoken glasses turn
    /// (inputProvenance.sourceChannel).
    static let inputSourceChannel = "agentwearlink"

    static let voiceStylePrompt = """
    이 요청은 사용자가 스마트 안경으로 말한 것이고, 답은 음성으로 읽힙니다. \
    두세 문장 이내로 짧게, 말하듯이 답하세요. 마크다운, 목록, 표, 링크, 이모지는 쓰지 마세요.
    """

    /// - Parameters:
    ///   - telegramChatID: when set, the Gateway also posts the agent's final
    ///     reply to this Telegram chat. Empty or non-numeric turns it off.
    ///   - voiceStyle: asks the agent for a short, speakable answer.
    static func make(
        telegramChatID: String = "",
        telegramAccountID: String = "default",
        voiceStyle: Bool = false
    ) -> OpenClawAgentTurnOptions {
        let chatID = telegramChatID.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = chatID.hasPrefix("-") ? chatID.dropFirst() : Substring(chatID)
        let isChatID = !digits.isEmpty
            && digits.allSatisfy { $0.isASCII && $0.isNumber }
        return OpenClawAgentTurnOptions(
            replyDelivery: isChatID
                ? .init(channel: "telegram", to: chatID, accountId: telegramAccountID)
                : nil,
            extraSystemPrompt: voiceStyle ? voiceStylePrompt : nil,
            inputSourceChannel: inputSourceChannel
        )
    }
}

/// Owns the wake-phrase gate on one actor for the DAT callback and the echo guard.
actor AWLWakeGateBox {
    private let gate: AWLWakePhraseGate
    /// Echo window: everything is ignored until this time.
    private var echoUntil: Date?
    private var speechEnd: Date?
    private var pendingUtterances = 0
    static let secondsPerCharacter = 0.18
    static let echoTail: TimeInterval = 4
    static let maximumEstimate: TimeInterval = 120

    init(gate: AWLWakePhraseGate) {
        self.gate = gate
    }

    func evaluate(_ text: String) -> AWLWakePhraseGate.Decision {
        if let echoUntil, Date() < echoUntil { return .ignore }
        return gate.evaluate(text)
    }

    /// Started with an estimate in case the finish callback never comes.
    /// Queued sentences extend the estimated end one after another.
    func beganSpeaking(_ text: String) {
        let now = Date()
        let estimate = min(Double(text.count) * Self.secondsPerCharacter, Self.maximumEstimate)
        let start = max(speechEnd ?? now, now)
        speechEnd = start.addingTimeInterval(estimate)
        pendingUtterances += 1
        echoUntil = speechEnd?.addingTimeInterval(Self.echoTail)
    }

    /// The synthesizer really finished: end at now + tail.
    func finishedSpeaking() {
        pendingUtterances = max(0, pendingUtterances - 1)
        guard pendingUtterances == 0 else { return }
        speechEnd = nil
        echoUntil = Date().addingTimeInterval(Self.echoTail)
    }

    func arm() {
        gate.arm()
    }

    func suppress(until date: Date) {
        gate.suppress(until: date)
    }
}

/// Settings needed to rebuild the runtime without the user (token omitted:
/// recovery always uses the stored, endpoint-scoped device grant).
struct AWLConnectRequest {
    let hostname: String
    let sessionKey: String
    let enableVision: Bool
    let experimentalStandalonePhoto: Bool
    let voiceOnly: Bool
    let voiceWake: Bool
    let turnOptions: OpenClawAgentTurnOptions
}
