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
    private var eventTask: Task<Void, Never>?
    private var readinessTask: Task<Void, Never>?

    func start() async {
        guard device == nil else { return }
        let adapter = MetaDATDeviceAdapter(diagnostics: diagnostics)
        device = adapter

        // Subscribe before activating the listener, as production Core does.
        let events = adapter.events()
        eventTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                if case .invocation = event {
                    self?.status = "voice-acknowledged"
                }
            }
        }

        // No DeviceSession, microphone, camera, Gateway or agent is started.
        await adapter.startVoiceInvocationListening()

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
        eventTask?.cancel()
        readinessTask = nil
        eventTask = nil
        if let device {
            await device.stopVoiceInvocationListening()
        }
        device = nil
        status = "voice-stopped"
    }
}
