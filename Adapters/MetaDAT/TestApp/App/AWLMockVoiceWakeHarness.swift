import AgentWearLinkCore
import AgentWearLinkMetaDATIntegration
import AgentWearLinkMetaDATTestSupport
import Foundation
import SwiftUI

/// App-hosted vendor MockDeviceKit → Voice Invocation → foreground DAT Speech
/// → actual Core Runtime → isolated MockAgentAdapter turn. Never uses personal
/// Gateway credentials, network, camera or release app configuration.
@MainActor
final class AWLMockVoiceWakeHarness: ObservableObject {
    @Published private(set) var status = "wake-waiting"
    @Published private(set) var mediaStatus = "wake-media-pending"
    private let diagnostics = AWLDiagnosticRecorder(capacity: 32)
    private var adapter: MetaDATDeviceAdapter?
    private var runtime: AgentWearLinkRuntime?
    private var readinessTask: Task<Void, Never>?
    private var sawAgentText = false

    func start() async {
        guard runtime == nil else { return }
        let lifecycle = MetaDATApplicationLifecycle(initialPhase: .foreground)
        let vendor = MetaDATDeviceAdapter(
            applicationLifecycle: lifecycle,
            diagnostics: diagnostics
        )
        let composed = AgentWearLinkRuntime(
            device: MetaDATVoiceWakeDeviceAdapter(vendor: vendor),
            agent: MockAgentAdapter(),
            diagnostics: diagnostics,
            output: { [weak self] event in
                await MainActor.run {
                    switch event {
                    case .invocation:
                        self?.status = "wake-acknowledged"
                    case let .text(_, text):
                        if text.contains("echo:") {
                            self?.sawAgentText = true
                        }
                    case .turnCompleted:
                        self?.status = self?.sawAgentText == true
                            ? "wake-agent-completed"
                            : "wake-agent-text-missing"
                    case .failed:
                        self?.status = "wake-runtime-event-failed"
                    default:
                        break
                    }
                }
            }
        )
        adapter = vendor
        runtime = composed
        do {
            try await composed.start()
        } catch {
            await composed.stop()
            runtime = nil
            adapter = nil
            status = "wake-runtime-start-failed"
            return
        }

        readinessTask = Task { [weak self] in
            for _ in 0..<250 {
                guard !Task.isCancelled else { return }
                if vendor.capabilities.contains(.voiceInvocation),
                   self?.status == "wake-waiting" {
                    self?.status = "wake-listening"
                }
                if vendor.capabilities.contains(.speechInput) {
                    self?.mediaStatus = "wake-speech-ready"
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            self?.mediaStatus = "wake-speech-unavailable"
        }
    }

    func sendFinalTranscript() {
        guard mediaStatus == "wake-speech-ready" else { return }
        do {
            try MetaDATMockHostBootstrap.sendFinalMockTranscript(
                "AWL deterministic hands-free agent check"
            )
        } catch {
            status = "wake-transcript-injection-failed"
        }
    }

    func stop() async {
        readinessTask?.cancel()
        readinessTask = nil
        await runtime?.stop()
        runtime = nil
        adapter = nil
        status = "wake-stopped"
    }
}
