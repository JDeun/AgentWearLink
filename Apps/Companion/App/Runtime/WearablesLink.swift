import AgentWearLinkCore
import AgentWearLinkMetaDATIntegration
import Foundation
import MWDATCore

/// Thin, main-actor wrapper around the Meta Wearables SDK. Every SDK call is
/// guarded by `isConfigured`: `Wearables.shared` must not be touched before
/// `Wearables.configure()` succeeded (an unprovisioned or simulator build).
@MainActor
final class WearablesLink {
    enum Configuration: Equatable {
        /// Team ID / callback scheme missing from this build (no local xcconfig).
        case notProvisioned
        case configured
        case failed
    }

    private(set) var configuration: Configuration?
    private var observers: [Task<Void, Never>] = []
    private var deviceTokens: [any AnyListenerToken] = []
    private var invocationChannel: MetaDATVoiceInvocationChannel?
    private var invocationReady: Bool?

    var isConfigured: Bool { configuration == .configured }

    var isRegistered: Bool {
        isConfigured && Wearables.shared.registrationState == .registered
    }

    func configure() -> Configuration {
        if let configuration { return configuration }
        let result: Configuration
        if Self.hasProvisionedRegistration(Bundle.main) {
            do {
                try Wearables.configure()
                result = .configured
            } catch {
                // Never surface SDK error text; it may echo registration details.
                result = .failed
            }
        } else {
            result = .notProvisioned
        }
        configuration = result
        return result
    }

    /// TeamID and callback scheme are always required. Meta App ID and Client
    /// Token are optional in Meta AI Developer Mode (empty values), but an
    /// unexpanded build setting or the "0" CI placeholder is rejected.
    static func hasProvisionedRegistration(_ bundle: Bundle) -> Bool {
        guard let registration = bundle.object(forInfoDictionaryKey: "MWDAT") as? [String: Any],
              isOptionalCredential(registration["MetaAppID"]),
              isOptionalCredential(registration["ClientToken"]),
              let teamID = registration["TeamID"] as? String,
              !teamID.isEmpty, !teamID.contains("$("),
              let link = registration["AppLinkURLScheme"] as? String,
              link.contains("://"), !link.contains("$("), link != "://" else {
            return false
        }
        return true
    }

    private static func isOptionalCredential(_ value: Any?) -> Bool {
        guard let value else { return true }
        guard let string = value as? String else { return false }
        if string.isEmpty { return true }
        return string != "0" && !string.contains("$(")
    }

    // MARK: Registration

    func startRegistration() async -> Bool {
        guard isConfigured else { return false }
        do {
            try await MetaDATRegistration().start()
            return true
        } catch {
            return false
        }
    }

    func handleCallback(_ url: URL) async -> Bool {
        guard isConfigured else { return false }
        return (try? await MetaDATRegistration().handleCallback(url)) ?? false
    }

    // MARK: Glasses state

    func snapshot() -> GlassesSnapshot {
        GlassesStateMapper.snapshot(registered: isRegistered, devices: observations())
    }

    /// Vendor-free observations of every known device, for the pure policies.
    func observedDevices() -> [GlassesDeviceObservation] {
        observations()
    }

    var hasConnectedDevice: Bool {
        GlassesStateMapper.hasConnectedDevice(observations())
    }

    var speechDecision: SpeechPowerPolicy.Decision {
        GlassesStateMapper.speechDecision(observations())
    }

    /// Connected and usable for Speech (worn, unfolded, not too hot).
    func waitForUsableDevice(pollInterval: Duration = .seconds(2)) async {
        guard isConfigured else { return }
        while !Task.isCancelled {
            if isRegistered, hasConnectedDevice, speechDecision == .listen { return }
            try? await Task.sleep(for: pollInterval)
        }
    }

    private func observations() -> [GlassesDeviceObservation] {
        guard isConfigured else { return [] }
        let wearables = Wearables.shared
        return wearables.devices.compactMap { wearables.deviceForIdentifier($0) }.map { device in
            let link: GlassesDeviceObservation.Link
            switch device.linkState {
            case .connected: link = .connected
            case .connecting: link = .connecting
            default: link = .disconnected
            }
            let compatibility = device.compatibility()
            let wear: SpeechPowerPolicy.Wear
            switch device.donState {
            case .donned: wear = .worn
            case .doffed: wear = .notWorn
            default: wear = .unknown
            }
            let hinge: SpeechPowerPolicy.Hinge
            switch device.hingeState {
            case .open: hinge = .open
            case .closed: hinge = .folded
            default: hinge = .unknown
            }
            // Every level is kept: the thermal stages (ThermalStageTracker)
            // follow Meta's LIGHT / MODERATE / SEVERE+ guidance.
            let thermal: SpeechPowerPolicy.Thermal
            switch device.thermalLevel {
            case .none: thermal = .normal
            case .light: thermal = .light
            case .moderate: thermal = .moderate
            case .severe: thermal = .severe
            case .critical: thermal = .critical
            case .emergency: thermal = .emergency
            case .shutdown: thermal = .shutdown
            case .unknown: thermal = .unknown
            }
            let update: GlassesUpdateTarget?
            switch compatibility {
            case .deviceUpdateRequired: update = .glassesFirmware
            case .sdkUpdateRequired: update = .companionApp
            default: update = nil
            }
            return GlassesDeviceObservation(
                link: link,
                update: update,
                battery: device.batteryLevel,
                charging: device.chargingState == .charging,
                wear: wear,
                hinge: hinge,
                thermal: thermal
            )
        }
    }

    /// Checks silently; never switches to the Meta AI app.
    func microphonePermission() async -> ConnectionSignals.Permission {
        guard isRegistered else { return .unknown }
        do {
            return try await Wearables.shared.checkPermissionStatus(.microphone) == .granted
                ? .granted : .denied
        } catch {
            // No glasses connected right now: the status is simply unknown.
            return .unknown
        }
    }

    /// Asks through the Meta AI app; only after an explicit user action.
    func requestMicrophone() async -> ConnectionSignals.Permission {
        guard isRegistered else { return .unknown }
        if await microphonePermission() == .granted { return .granted }
        do {
            return try await Wearables.shared.requestPermission(.microphone) == .granted
                ? .granted : .denied
        } catch {
            return .unknown
        }
    }

    // MARK: Voice invocations

    /// "Hey Meta, start <app name>": Meta AI launches or foregrounds the app
    /// and delivers a LaunchApp invocation, which the channel acknowledges
    /// at once (sendSuccess) before `onLaunch` runs.
    ///
    /// Meta's docs say to open the stream early (app scope) so a cold launch
    /// does not miss the command, so it starts here, right after configure,
    /// independent of the DAT session and the Gateway, and keeps running
    /// across session restarts. The channel itself waits for registration
    /// and re-selects the device when the link or device list changes.
    ///
    /// Field notes: Korean launch phrases are reported not to work (only the
    /// English "Hey Meta, start/open Agent Wear Link", spacing exact), and
    /// delivery in Developer Mode is unreliable; a release channel is
    /// recommended for testing (dat-ios discussion #326).
    func startVoiceInvocations(
        diagnostics: AWLDiagnosticRecorder?,
        onLog: @escaping @MainActor @Sendable (String) -> Void,
        onLaunch: @escaping @MainActor @Sendable () -> Void
    ) {
        guard isConfigured, invocationChannel == nil else { return }
        let channel = MetaDATVoiceInvocationChannel(
            wearables: Wearables.shared,
            diagnostics: diagnostics,
            onEvent: { event in
                Task { @MainActor in
                    switch event {
                    case .invocation: onLaunch()
                    case .failed: onLog("voice invocation: acknowledgement not delivered")
                    default: break
                    }
                }
            },
            onReadiness: { [weak self] ready in
                Task { @MainActor in
                    guard let self, self.invocationReady != ready else { return }
                    self.invocationReady = ready
                    onLog(ready ? "voice invocation: listening" : "voice invocation: not listening")
                }
            }
        )
        invocationChannel = channel
        channel.start()
    }

    // MARK: Observation

    /// Calls `onChange` whenever registration, the device list or a device's
    /// state changes.
    func observe(onChange: @escaping @MainActor () -> Void) {
        guard isConfigured, observers.isEmpty else { return }
        let wearables = Wearables.shared
        observers.append(Task { @MainActor in
            for await _ in wearables.registrationStateStream() {
                if Task.isCancelled { return }
                onChange()
            }
        })
        observers.append(Task { @MainActor [weak self] in
            for await identifiers in wearables.devicesStream() {
                if Task.isCancelled { return }
                await self?.listenToDevices(identifiers, onChange: onChange)
                onChange()
            }
        })
    }

    private func listenToDevices(
        _ identifiers: [DeviceIdentifier],
        onChange: @escaping @MainActor () -> Void
    ) async {
        let old = deviceTokens
        deviceTokens = []
        for token in old { await token.cancel() }
        let wearables = Wearables.shared
        for identifier in identifiers {
            guard let device = wearables.deviceForIdentifier(identifier) else { continue }
            deviceTokens.append(device.addDeviceStateListener { _ in
                Task { @MainActor in onChange() }
            })
            deviceTokens.append(device.addLinkStateListener { _ in
                Task { @MainActor in onChange() }
            })
        }
    }

    /// Returns once registered glasses are actually connected (unfolded and
    /// near the phone). Paired glasses in the case are listed by the SDK but
    /// not connected, so the device list alone is not enough. Polls a local
    /// SDK property; cancellable.
    func waitForConnectedDevice(pollInterval: Duration = .seconds(2)) async {
        guard isConfigured else { return }
        while !Task.isCancelled {
            if isRegistered, hasConnectedDevice { return }
            try? await Task.sleep(for: pollInterval)
        }
    }
}
