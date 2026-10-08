import SwiftUI
import AgentWearLinkCore
import AgentWearLinkOpenClaw
import AgentWearLinkAppleOutput
import AgentWearLinkMetaDATIntegration
import AgentWearLinkMetaDATTestSupport

@main
struct MetaDATTestHostApp: App {
    @State private var state = "host-starting"
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var referenceHost = AWLReferenceRuntimeHost()
    @StateObject private var mockVoice = AWLMockVoiceInvocationHarness()
    @StateObject private var mockWake = AWLMockVoiceWakeHarness()
    @StateObject private var mockPhoto = AWLMockPhotoSnapshotHarness()
    @State private var gatewayHostname = ""
    @State private var bootstrapToken = ""
    @State private var targetSessionKey = ""
    @State private var allowVision = false
    @State private var experimentalStandalonePhoto = false
    @State private var photoPrompt = "Describe the photo."
    // Opt-in *foreground launch* convenience. Only non-secret endpoint and
    // session metadata are stored; the approved device grant stays in Keychain.
    @AppStorage("awl.reference.voiceWakeStartupEnabled")
    private var voiceWakeStartupEnabled = false
    @AppStorage("awl.reference.voiceWakeStartupHostname")
    private var voiceWakeStartupHostname = ""
    @AppStorage("awl.reference.voiceWakeStartupSession")
    private var voiceWakeStartupSession = ""
    @State private var voiceWakeStartupStatus = "auto-wake-disabled"
    @State private var attemptedVoiceWakeThisLaunch = false

    var body: some Scene {
        WindowGroup {
            VStack {
                Text(state)
                    .accessibilityIdentifier("awl-meta-host-state")
                if ProcessInfo.processInfo.arguments.contains(
                    MetaDATMockHostBootstrap.voiceLaunchArgument
                ) {
                    Text(mockVoice.status)
                        .accessibilityIdentifier("awl-meta-voice-state")
                }
                if ProcessInfo.processInfo.arguments.contains(
                    MetaDATMockHostBootstrap.wakeLaunchArgument
                ) {
                    Text(mockWake.status)
                        .accessibilityIdentifier("awl-meta-wake-state")
                    Text(mockWake.mediaStatus)
                        .accessibilityIdentifier("awl-meta-wake-media-state")
                    Button("Inject deterministic mock Speech transcript") {
                        mockWake.sendFinalTranscript()
                    }
                    .accessibilityIdentifier("awl-meta-send-mock-transcript")
                    .disabled(mockWake.mediaStatus != "wake-speech-ready")
                }
                if ProcessInfo.processInfo.arguments.contains(
                    MetaDATMockHostBootstrap.photoLaunchArgument
                ) {
                    Text(mockPhoto.status)
                        .accessibilityIdentifier("awl-meta-photo-state")
                }
                Button("Configure mock still fixture") {
                    Task {
                        do {
                            let imageURL = try MetaDATMockStillFixture.write(
                                to: FileManager.default.temporaryDirectory
                            )
                            _ = try MetaDATMockHostBootstrap.configureCapturedPhotoFixture(
                                fileURL: imageURL
                            )
                            state = "photo-fixture-ready"
                        } catch {
                            state = "photo-fixture-error"
                        }
                    }
                }
                .accessibilityIdentifier("awl-meta-configure-photo-fixture")
                .disabled(!ProcessInfo.processInfo.arguments.contains(
                    MetaDATMockHostBootstrap.launchArgument
                ))
                if ProcessInfo.processInfo.arguments.contains(
                    MetaDATMockHostBootstrap.photoLaunchArgument
                ) {
                    Button("Capture mock photo through production adapter") {
                        Task { await mockPhoto.captureOnce() }
                    }
                    .accessibilityIdentifier("awl-meta-capture-mock-photo")
                    .disabled(state != "photo-fixture-ready")
                    // DEBUG-only explicit opt-in: pinned DAT 1.0.0 marks
                    // standalone Camera.photo experimental/non-publishable.
                    Button("Capture experimental standalone mock photo") {
                        Task {
                            await mockPhoto.captureOnce(experimentalStandalonePhoto: true)
                        }
                    }
                    .accessibilityIdentifier("awl-meta-capture-experimental-photo")
                    .disabled(state != "photo-fixture-ready")
                    Button("Fail next experimental standalone photo") {
                        do {
                            try MetaDATMockHostBootstrap.failNextMockStandalonePhotoCapture()
                        } catch {
                            state = "experimental-photo-fault-setup-failed"
                        }
                    }
                    .accessibilityIdentifier("awl-meta-fail-standalone-photo")
                    .disabled(state != "photo-fixture-ready")
                    Button("Deny mock camera permission") {
                        do {
                            try MetaDATMockHostBootstrap.denyMockCameraPermission()
                        } catch {
                            state = "photo-permission-fault-setup-failed"
                        }
                    }
                    .accessibilityIdentifier("awl-meta-deny-camera-permission")
                    .disabled(state != "photo-fixture-ready")
                }

                if !ProcessInfo.processInfo.arguments.contains(
                    MetaDATMockHostBootstrap.launchArgument
                ) {
                    ScrollView {
                        VStack(spacing: 8) {
                    Text(referenceHost.status)
                        .accessibilityIdentifier("awl-reference-runtime-state")
                    TextField("Mac mini hostname (*.ts.net)", text: $gatewayHostname)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("awl-gateway-hostname")
                    Text(voiceWakeStartupStatus)
                        .accessibilityIdentifier("awl-auto-wake-state")
                    if voiceWakeStartupEnabled {
                        Button("Disable foreground voice-wake startup") {
                            voiceWakeStartupEnabled = false
                            voiceWakeStartupHostname = ""
                            voiceWakeStartupSession = ""
                            voiceWakeStartupStatus = "auto-wake-disabled"
                        }
                        .accessibilityIdentifier("awl-disable-auto-wake")
                    } else {
                        Button("Enable next foreground launch (approved grant only)") {
                            let hostname = gatewayHostname.trimmingCharacters(
                                in: .whitespacesAndNewlines
                            )
                            guard (try? OpenClawEndpoint.tailnetServe(hostname: hostname))
                                    != nil else {
                                voiceWakeStartupStatus = "auto-wake-invalid-private-host"
                                return
                            }
                            voiceWakeStartupHostname = hostname
                            voiceWakeStartupSession = targetSessionKey.trimmingCharacters(
                                in: .whitespacesAndNewlines
                            )
                            voiceWakeStartupEnabled = true
                            voiceWakeStartupStatus = "auto-wake-armed-for-next-launch"
                        }
                        .accessibilityIdentifier("awl-enable-auto-wake")
                    }
                    SecureField("Gateway token (first approval; optional on approved reconnect)", text: $bootstrapToken)
                        .accessibilityIdentifier("awl-gateway-token")
                    TextField("Existing OpenClaw session key (optional)", text: $targetSessionKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("awl-openclaw-session-key")
                    Toggle("Enable vision only for a verified image-capable OpenClaw model", isOn: $allowVision)
                        .accessibilityIdentifier("awl-vision-opt-in")
                    #if DEBUG
                    Toggle(
                        "Experimental standalone Camera.photo (non-publishable)",
                        isOn: $experimentalStandalonePhoto
                    )
                    .accessibilityIdentifier("awl-experimental-photo-opt-in")
                    .disabled(!allowVision)
                    #endif
                    Text(referenceHost.gatewayHealthStatus)
                        .accessibilityIdentifier("awl-gateway-health-state")
                    Button("Check Gateway health (read-only, no glasses)") {
                        let suppliedToken = bootstrapToken
                        bootstrapToken = ""
                        Task {
                            await referenceHost.checkReadOnlyGatewayHealth(
                                hostname: gatewayHostname,
                                token: suppliedToken
                            )
                        }
                    }
                    .accessibilityIdentifier("awl-gateway-health-check")
                    Button("Connect reference runtime") {
                        let suppliedToken = bootstrapToken
                        bootstrapToken = ""
                        Task {
                            await referenceHost.connect(
                                hostname: gatewayHostname,
                                token: suppliedToken,
                                sessionKey: targetSessionKey,
                                enableVision: allowVision,
                                experimentalStandalonePhoto: experimentalStandalonePhoto
                            )
                        }
                    }
                    .accessibilityIdentifier("awl-reference-connect")
                    Button("Connect voice-only (no media session)") {
                        let suppliedToken = bootstrapToken
                        bootstrapToken = ""
                        Task {
                            await referenceHost.connect(
                                hostname: gatewayHostname,
                                token: suppliedToken,
                                sessionKey: targetSessionKey,
                                enableVision: false,
                                voiceOnly: true
                            )
                        }
                    }
                    .accessibilityIdentifier("awl-reference-voice-only-connect")
                    Button("Connect hands-free wake + Speech (foreground)") {
                        let suppliedToken = bootstrapToken
                        bootstrapToken = ""
                        Task {
                            await referenceHost.connect(
                                hostname: gatewayHostname,
                                token: suppliedToken,
                                sessionKey: targetSessionKey,
                                enableVision: false,
                                voiceWake: true
                            )
                        }
                    }
                    .accessibilityIdentifier("awl-reference-voice-wake-connect")
                    TextField("Photo question", text: $photoPrompt)
                        .accessibilityIdentifier("awl-photo-prompt")
                    Button("Capture one photo and ask OpenClaw") {
                        Task { await referenceHost.captureAndAsk(prompt: photoPrompt) }
                    }
                    .accessibilityIdentifier("awl-reference-photo")
                    Button("Disconnect reference runtime") {
                        Task { await referenceHost.disconnect() }
                    }
                    .accessibilityIdentifier("awl-reference-disconnect")
                    Button("Copy sanitized diagnostics") {
                        referenceHost.copySanitizedDiagnostics()
                    }
                    .accessibilityIdentifier("awl-copy-sanitized-diagnostics")
                    Button("Register with Meta AI") {
                        Task { await referenceHost.startRegistration() }
                    }
                    .accessibilityIdentifier("awl-meta-register")
                        }
                    }
                    .accessibilityIdentifier("awl-reference-controls-scroll")
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                Task {
                    await referenceHost.applicationPhase(
                        newPhase == .active ? .foreground : .background
                    )
                    if newPhase == .active, state == "host-ready" {
                        await startOptedInForegroundVoiceWakeOnce()
                    }
                }
            }
            .onOpenURL { url in
                Task { await referenceHost.handleMetaCallback(url) }
            }
            .task {
                    guard ProcessInfo.processInfo.arguments.contains(
                        MetaDATMockHostBootstrap.launchArgument
                    ) else {
                        await referenceHost.configureWearables()
                        state = "host-ready"
                        if scenePhase == .active {
                            await startOptedInForegroundVoiceWakeOnce()
                        }
                        return
                    }

                    do {
                        try await MetaDATMockHostBootstrap.configureIfRequested()

                        guard let portFile = ProcessInfo.processInfo.environment[
                            MetaDATMockHostBootstrap.portFileEnvironment
                        ], !portFile.isEmpty else {
                            state = "host-error"
                            return
                        }

                        for _ in 0..<50 {
                            if FileManager.default.fileExists(atPath: portFile) {
                                if ProcessInfo.processInfo.arguments.contains(
                                    MetaDATMockHostBootstrap.voiceLaunchArgument
                                ) {
                                    await mockVoice.start()
                                }
                                if ProcessInfo.processInfo.arguments.contains(
                                    MetaDATMockHostBootstrap.wakeLaunchArgument
                                ) {
                                    await mockWake.start()
                                }
                                state = "host-ready"
                                return
                            }
                            try? await Task.sleep(for: .milliseconds(100))
                        }

                        state = "host-error"
                    } catch {
                        NSLog("[AgentWearLinkMetaDATTestHost] bootstrap failed (details redacted)")
                        state = "host-error"
                    }
                }
        }
    }

    @MainActor
    private func startOptedInForegroundVoiceWakeOnce() async {
        // Does not launch an iOS process in the background or assume special
        // Hey Meta/lock-screen privileges. Once per foreground app process only.
        guard voiceWakeStartupEnabled,
              !attemptedVoiceWakeThisLaunch,
              scenePhase == .active,
              !ProcessInfo.processInfo.arguments.contains(
                  MetaDATMockHostBootstrap.launchArgument
              ) else { return }
        attemptedVoiceWakeThisLaunch = true

        // Explicit, validated Tailnet hostname is the only persisted route.
        // The original bearer is never persisted or restored; #590's scoped
        // approved Keychain grant admission must pass before socket startup.
        voiceWakeStartupStatus = "auto-wake-connecting"
        await referenceHost.connect(
            hostname: voiceWakeStartupHostname,
            token: "",
            sessionKey: voiceWakeStartupSession,
            enableVision: false,
            voiceWake: true
        )
        voiceWakeStartupStatus = referenceHost.status == "voice-wake-runtime-started"
            ? "auto-wake-runtime-started"
            : "auto-wake-needs-foreground-approval-or-setup"
    }
}
