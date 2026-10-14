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

    struct GlassesSnapshot: Equatable {
        var glasses: ConnectionSignals.Glasses
        var battery: Int?
        var charging: Bool
    }

    private(set) var configuration: Configuration?
    private var observers: [Task<Void, Never>] = []
    private var deviceTokens: [any AnyListenerToken] = []

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
        guard isConfigured else {
            return GlassesSnapshot(glasses: .registrationRequired, battery: nil, charging: false)
        }
        let wearables = Wearables.shared
        guard wearables.registrationState == .registered else {
            return GlassesSnapshot(glasses: .registrationRequired, battery: nil, charging: false)
        }
        let devices = wearables.devices.compactMap { wearables.deviceForIdentifier($0) }
        guard let device = devices.first(where: { $0.linkState == .connected }) ?? devices.first else {
            return GlassesSnapshot(glasses: .waiting, battery: nil, charging: false)
        }
        let charging = device.chargingState == .charging
        switch device.compatibility() {
        case .deviceUpdateRequired, .sdkUpdateRequired:
            return GlassesSnapshot(glasses: .updateRequired, battery: device.batteryLevel, charging: charging)
        default:
            break
        }
        let glasses: ConnectionSignals.Glasses
        switch device.linkState {
        case .connected: glasses = .connected
        case .connecting: glasses = .connecting
        default: glasses = .waiting
        }
        return GlassesSnapshot(
            glasses: glasses,
            battery: glasses == .connected ? device.batteryLevel : nil,
            charging: charging
        )
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

    /// Returns once the SDK lists at least one device (glasses unfolded and
    /// near the phone). The first stream value arrives immediately.
    func waitForDevice() async {
        guard isConfigured else { return }
        for await identifiers in Wearables.shared.devicesStream() {
            if Task.isCancelled || !identifiers.isEmpty { return }
        }
    }
}
