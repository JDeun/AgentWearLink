#if DEBUG
import AgentWearLinkCore
import AgentWearLinkMetaDATIntegration
import Foundation
import MWDATCore
import SwiftUI

/// App-hosted vendor-contract regression only. No real account, radio,
/// camera, microphone, Gateway, or Meta AI navigation is used.
@MainActor
final class AWLMockSessionLifecycleHarness: ObservableObject {
    @Published private(set) var status = "lifecycle-idle"
    @Published private(set) var running = false

    private enum Failure: Error { case unexpectedState, timeout }

    func run(unregistered: Bool) async {
        guard !running else { return }
        running = true
        defer { running = false }
        status = "lifecycle-running"
        var stage = "registration"
        do {
            let wearables = Wearables.shared
            if unregistered {
                guard wearables.registrationState != .registered else {
                    throw Failure.unexpectedState
                }
                stage = "sdk-create-unregistered"
                do {
                    let unexpected = try wearables.createSession(
                        deviceSelector: AutoDeviceSelector(wearables: wearables)
                    )
                    unexpected.stop()
                    throw Failure.unexpectedState
                } catch DeviceSessionError.notRegistered {
                    // DAT 1.1 guarantees the typed creation rejection.
                }

                stage = "adapter-connect-unregistered"
                let adapter = MetaDATDeviceAdapter(connectTimeout: .seconds(5))
                do {
                    try await adapter.connect()
                    await adapter.disconnect()
                    throw Failure.unexpectedState
                } catch let error as AWLError {
                    await adapter.disconnect()
                    guard error == .device("Meta DAT application is not registered"),
                          adapter.capabilities.isEmpty else {
                        throw Failure.unexpectedState
                    }
                }
                status = "lifecycle-unregistered-verified"
                return
            }

            guard wearables.registrationState == .registered else {
                throw Failure.unexpectedState
            }
            stage = "ready-device"
            try await waitUntil {
                wearables.devices.contains { identifier in
                    guard let device = wearables.deviceForIdentifier(identifier) else { return false }
                    return device.linkState == .connected && device.compatibility() == .compatible
                }
            }
            guard let selected = wearables.devices.first(where: { identifier in
                guard let device = wearables.deviceForIdentifier(identifier) else { return false }
                return device.linkState == .connected && device.compatibility() == .compatible
            }) else { throw Failure.unexpectedState }

            stage = "create"
            let session = try wearables.createSession(
                deviceSelector: SpecificDeviceSelector(device: selected)
            )
            defer { session.stop() }

            // One stream, subscribed before start. Verify published transitions
            // in addition to the synchronous state snapshot.
            let states = session.stateStream()
            var lastState: DeviceSessionState?
            var streamEnded = false
            let observer = Task { @MainActor in
                for await state in states {
                    guard !Task.isCancelled else { return }
                    lastState = state
                }
                streamEnded = true
            }
            defer { observer.cancel() }

            stage = "idle-no-op"
            guard session.state == .idle else { throw Failure.unexpectedState }
            session.pause()
            session.resume()
            guard session.state == .idle else { throw Failure.unexpectedState }

            stage = "start"
            try session.start()
            try await waitUntil { session.state == .started && lastState == .started }

            stage = "resume-started-no-op"
            session.resume()
            guard session.state == .started else { throw Failure.unexpectedState }

            stage = "pause"
            session.pause()
            try await waitUntil { session.state == .paused && lastState == .paused }

            stage = "pause-paused-no-op"
            session.pause()
            guard session.state == .paused else { throw Failure.unexpectedState }

            stage = "resume"
            session.resume()
            try await waitUntil { session.state == .started && lastState == .started }

            stage = "stop"
            session.stop()
            try await waitUntil {
                session.state == .stopped && lastState == .stopped && streamEnded
            }
            stage = "stopped-no-op"
            session.pause()
            session.resume()
            guard session.state == .stopped else { throw Failure.unexpectedState }
            status = "lifecycle-pause-resume-verified"
        } catch {
            // Fixed stage names only: no SDK error descriptions or identifiers.
            status = "lifecycle-failed-" + stage
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(8))
        while !condition() {
            try Task.checkCancellation()
            guard clock.now < deadline else { throw Failure.timeout }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
#endif
