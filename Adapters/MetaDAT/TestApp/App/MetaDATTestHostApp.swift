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
    @State private var gatewayHostname = ""
    @State private var bootstrapToken = ""
    @State private var targetSessionKey = ""
    @State private var allowVision = false
    @State private var photoPrompt = "Describe the photo."

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

                if !ProcessInfo.processInfo.arguments.contains(
                    MetaDATMockHostBootstrap.launchArgument
                ) {
                    Text(referenceHost.status)
                        .accessibilityIdentifier("awl-reference-runtime-state")
                    TextField("Mac mini hostname (*.ts.net)", text: $gatewayHostname)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("awl-gateway-hostname")
                    SecureField("Development or deployment Gateway token", text: $bootstrapToken)
                        .accessibilityIdentifier("awl-gateway-token")
                    TextField("Existing OpenClaw session key (optional)", text: $targetSessionKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("awl-openclaw-session-key")
                    Toggle("Enable vision only for a verified image-capable OpenClaw model", isOn: $allowVision)
                        .accessibilityIdentifier("awl-vision-opt-in")
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
                                enableVision: allowVision
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
            .onChange(of: scenePhase) { _, newPhase in
                Task {
                    await referenceHost.applicationPhase(
                        newPhase == .active ? .foreground : .background
                    )
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
}
