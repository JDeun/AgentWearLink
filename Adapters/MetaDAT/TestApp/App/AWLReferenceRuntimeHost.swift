import AgentWearLinkAppleOutput
import AgentWearLinkCore
import AgentWearLinkMetaDATIntegration
import AgentWearLinkOpenClaw
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

    private let lifecycle = MetaDATApplicationLifecycle(initialPhase: .foreground)
    private let diagnostics = AWLDiagnosticRecorder(capacity: 256)
    private var runtime: AgentWearLinkRuntime? {
        // A foreground-only voice session dies when auto-lock suspends the
        // app, so keep the screen awake exactly while a runtime is live.
        didSet { UIApplication.shared.isIdleTimerDisabled = runtime != nil }
    }
    private var device: MetaDATDeviceAdapter?
    private var visionAgent: OpenClawNativeAgentAdapter?
    private var outputSink: AppleSpeechOutput?
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
        await lifecycle.transition(to: phase)
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
            let sink = AppleSpeechOutput(
                synthesizer: AVSpeechSynthesizerBridge(language: "ko-KR")
            )
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
    }

    private func clearRuntimeReferences() {
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
