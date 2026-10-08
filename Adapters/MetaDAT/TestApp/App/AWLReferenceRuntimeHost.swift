import AgentWearLinkAppleOutput
import AgentWearLinkCore
import AgentWearLinkMetaDATIntegration
import AgentWearLinkOpenClaw
import Foundation
import MWDATCore
import SwiftUI

/// Human-operated iOS reference composition. Neither test fixtures nor a
/// production Mac mini hostname, pairing identity, token or session key are
/// hardcoded into the application. Use the Meta test host's app identifier
/// and callback registration settings for the intended deployment.
@MainActor
final class AWLReferenceRuntimeHost: ObservableObject {
    @Published private(set) var status = "disconnected"

    private let lifecycle = MetaDATApplicationLifecycle(initialPhase: .foreground)
    private let diagnostics = AWLDiagnosticRecorder(capacity: 256)
    private var runtime: AgentWearLinkRuntime?
    private var device: MetaDATDeviceAdapter?
    private var configured = false

    func configureWearables() async {
        guard !configured else { return }
        do {
            try Wearables.configure()
            configured = true
        } catch {
            // The local operator can inspect native Meta registration
            // configuration; never embed SDK errors in exported diagnostics.
            status = "meta-configuration-failed"
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
        await lifecycle.transition(to: phase)
    }

    func connect(hostname: String, token: String, sessionKey: String) async {
        guard runtime == nil else {
            status = "already-connected"
            return
        }
        guard configured else {
            status = "meta-not-configured"
            return
        }
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            status = "gateway-token-required"
            return
        }

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
            let assembler = OpenClawConnectAssembler(
                identityManager: .init(
                    store: KeychainOpenClawDeviceIdentityStore(service: service)
                ),
                credentialStore: KeychainOpenClawDeviceCredentialStore(service: service),
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
                credentials: .init(token: token),
                clientIdentity: .backend,
                diagnostics: diagnostics
            )
            let agent = OpenClawNativeAgentAdapter(
                supervisor: supervisor,
                dispatcher: dispatcher,
                runClient: OpenClawAgentRunClient(dispatcher: dispatcher),
                sessionKey: sessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty ? nil : sessionKey
            )
            let concreteDevice = MetaDATDeviceAdapter(
                applicationLifecycle: lifecycle,
                diagnostics: diagnostics
            )
            let sink = AppleSpeechOutput(
                synthesizer: AVSpeechSynthesizerBridge(language: "ko-KR")
            )
            let composed = AgentWearLinkRuntime(
                device: concreteDevice,
                agent: agent,
                outputSink: sink,
                diagnostics: diagnostics
            )

            // Core itself first subscribes to device.events() before connecting
            // either transport, so no device event is lost during connect.
            runtime = composed
            device = concreteDevice
            do {
                try await composed.start()
                // Independent Voice Invocation startup follows the upstream
                // Meta channel PR (#543) and needs a separate iOS host flow.
                // Media + OpenClaw + Apple output are wired here already.
                status = "connected"
            } catch {
                await composed.stop()
                runtime = nil
                device = nil
                status = "connection-failed"
            }
        } catch {
            status = "invalid-private-gateway-config"
        }
    }

    func disconnect() async {
        status = "disconnecting"
        if let runtime {
            await runtime.stop()
        }
        runtime = nil
        device = nil
        status = "disconnected"
    }
}
