import AgentWearLinkCore
import AgentWearLinkMetaDATIntegration
import Foundation
import SwiftUI
import MWDATCore

/// App-hosted MockDeviceKit voice test only. Exercises the public concrete
/// MetaDATDeviceAdapter rather than a duplicate fake Voice Invocation source.
/// The actual mock transport is enabled only by MetaDATMockHostBootstrap.
@MainActor
final class AWLMockVoiceInvocationHarness: ObservableObject {
    @Published private(set) var status = "voice-waiting"
    private let diagnostics = AWLDiagnosticRecorder(capacity: 32)
    private var device: MetaDATDeviceAdapter?
    private var runtime: AgentWearLinkRuntime?
    private var readinessTask: Task<Void, Never>?

    func start() async {
        guard device == nil else { return }
        let adapter = MetaDATDeviceAdapter(diagnostics: diagnostics)
        device = adapter

        // Exercise the *production Core Runtime* and vendor-backed
        // VoiceOnlyDeviceAdapter, not a separate direct device.events()
        // consumer. This still uses a synthetic local agent for the app-hosted
        // mock test: no personal Gateway, credentials or media are touched.
        let composed = AgentWearLinkRuntime(
            device: MetaDATVoiceOnlyDeviceAdapter(vendor: adapter),
            agent: MockAgentAdapter(),
            diagnostics: diagnostics,
            output: { [weak self] event in
                if case .invocation = event {
                    await MainActor.run { self?.status = "voice-acknowledged" }
                }
            }
        )
        runtime = composed
        do {
            try await composed.start()
        } catch {
            await composed.stop()
            runtime = nil
            device = nil
            status = "voice-runtime-start-failed"
            return
        }

        readinessTask = Task { [weak self] in
            for _ in 0..<200 {
                guard !Task.isCancelled else { return }
                if adapter.capabilities.contains(.voiceInvocation) {
                    if self?.status == "voice-waiting" {
                        self?.status = "voice-listening"
                    }
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            if self?.status == "voice-waiting" {
                // Test-only, non-secret readiness fields reveal which
                // lifecycle precondition prevented a standalone lease.
                let wearables = Wearables.shared
                let isRegistered: Bool
                if case .registered = wearables.registrationState {
                    isRegistered = true
                } else {
                    isRegistered = false
                }
                let paired = wearables.devices
                let connected = paired.filter { identifier in
                    wearables.deviceForIdentifier(identifier)?.linkState == .connected
                }.count
                let lastKind = self?.diagnostics.snapshot().last?.kind.rawValue
                    ?? "no-diagnostic"
                self?.status = "voice-not-listening-r\(isRegistered)-d\(paired.count)-c\(connected)-e\(lastKind)"
            }
        }
    }

    func stop() async {
        readinessTask?.cancel()
        readinessTask = nil
        await runtime?.stop()
        runtime = nil
        device = nil
        status = "voice-stopped"
    }
}
