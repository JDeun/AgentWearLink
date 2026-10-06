import Foundation
import AgentWearLinkCore
import MWDATCore

/// First concrete device adapter for Meta Wearables DAT.
///
/// This target is intentionally iOS/vendor-specific and must be compiled only
/// from an iOS reference app that links MWDATCore. The root AWL Core package
/// does not depend on Meta DAT.
public actor MetaDATDeviceAdapter: DeviceAdapter {
    /// Capabilities are advertised only when their implementation exists.
    /// Camera/Speech/Voice Invocation are added in later slices.
    public nonisolated let capabilities: CapabilitySet = []

    private let wearables: any WearablesInterface
    private var deviceSession: DeviceSession?
    private var stateTask: Task<Void, Never>?
    private var errorTask: Task<Void, Never>?
    private var registrationTask: Task<Void, Never>?
    private var deviceMonitorTask: Task<Void, Never>?
    private var selectedDeviceListenerTask: Task<Void, Never>?
    private var eventContinuation: AsyncStream<InteractionEvent>.Continuation?
    private var stopping = false
    private let connectTimeout: Duration

    public init(
        wearables: any WearablesInterface = Wearables.shared,
        connectTimeout: Duration = .seconds(15)
    ) {
        self.wearables = wearables
        self.connectTimeout = connectTimeout
    }

    public nonisolated func events() -> AsyncStream<InteractionEvent> {
        AsyncStream { continuation in
            Task { await self.install(continuation) }
        }
    }

    private func install(
        _ continuation: AsyncStream<InteractionEvent>.Continuation
    ) {
        eventContinuation?.finish()
        eventContinuation = continuation
    }

    public func connect() async throws {
        guard deviceSession == nil else { return }

        stopping = false

        guard case .registered = wearables.registrationState else {
            throw AWLError.device("Meta DAT application is not registered")
        }

        registrationTask = Task { [weak self] in
            for await state in wearables.registrationStateStream() {
                guard !Task.isCancelled else { break }
                guard case .registered = state else {
                    await self?.handleRegistrationLoss()
                    break
                }
            }
        }

        let devices = wearables.devices.compactMap {
            self.wearables.deviceForIdentifier($0)
        }
        guard let selectedDevice = devices.min(by: {
            Self.deviceRank($0) < Self.deviceRank($1)
        }) else {
            tearDownSession()
            throw AWLError.device("Meta DAT has no paired device eligible for session selection")
        }
        guard selectedDevice.compatibility() == .compatible else {
            tearDownSession()
            throw AWLError.device("Selected Meta DAT device is not SDK-compatible")
        }

        let selectedIdentifier = selectedDevice.identifier
        selectedDeviceListenerTask = Task { [weak self] in
            await self?.monitorSelectedDeviceSignals(selectedDevice)
        }
        deviceMonitorTask = Task { [weak self] in
            await self?.monitorSelectedDevice(selectedIdentifier)
        }

        let selector = SpecificDeviceSelector(device: selectedIdentifier)
        let session: DeviceSession
        do {
            session = try wearables.createSession(deviceSelector: selector)
        } catch {
            tearDownSession()
            throw error
        }
        deviceSession = session

        // Obtain the streams before start() so initial state/error transitions
        // cannot be missed. Meta's current samples use the same ordering.
        let stateStream = session.stateStream()
        let errorStream = session.errorStream()

        errorTask = Task { [weak self] in
            for await error in errorStream {
                guard !Task.isCancelled else { break }
                await self?.emitDeviceError(error.localizedDescription)
            }
        }

        do {
            try session.start()

            try await waitUntilStarted(
                stateStream,
                timeout: connectTimeout
            )

            // Do not create a second stateStream() after consuming .started.
            // Continue the same stream in one observer so SDK stream semantics cannot
            // create a gap between startup and steady-state monitoring.
            stateTask = Task { [weak self] in
                for await state in stateStream {
                    guard !Task.isCancelled else { break }

                    if state == .stopped {
                        await self?.handleUnexpectedStop()
                        break
                    }
                }
            }
        } catch {
            tearDownSession()
            throw error
        }
    }

    private func monitorSelectedDeviceSignals(_ device: Device) async {
        let linkToken = device.addLinkStateListener { [weak self] state in
            guard state != .connected else { return }
            Task { await self?.handleSelectedDeviceUnavailable(
                "Selected Meta DAT device link became unavailable: \(state)"
            ) }
        }
        let compatibilityToken = device.addCompatibilityListener { [weak self] compatibility in
            guard compatibility != .compatible else { return }
            Task { await self?.handleSelectedDeviceUnavailable(
                "Selected Meta DAT device became incompatible: \(compatibility)"
            ) }
        }

        await withTaskCancellationHandler {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
            }
        } onCancel: {
            Task {
                await linkToken.cancel()
                await compatibilityToken.cancel()
            }
        }
        await linkToken.cancel()
        await compatibilityToken.cancel()
    }

    private func monitorSelectedDevice(_ selectedIdentifier: DeviceIdentifier) async {
        for await identifiers in wearables.devicesStream() {
            guard !Task.isCancelled else { break }
            guard identifiers.contains(selectedIdentifier),
                  let device = wearables.deviceForIdentifier(selectedIdentifier) else {
                handleSelectedDeviceUnavailable(
                    "Selected Meta DAT device is no longer paired/available"
                )
                return
            }

            let compatibility = device.compatibility()
            guard compatibility == .compatible else {
                handleSelectedDeviceUnavailable(
                    "Selected Meta DAT device became incompatible: \(compatibility)"
                )
                return
            }
        }
    }

    private func handleSelectedDeviceUnavailable(_ message: String) {
        guard !stopping, deviceSession != nil else { return }
        eventContinuation?.yield(.failed(nil, .device(message)))
        tearDownSession()
    }

    private nonisolated static func deviceRank(_ device: Device) -> Int {
        if device.linkState == .connected && device.donState == .donned { return 0 }
        if device.linkState == .connected { return 1 }
        if device.compatibility() == .compatible { return 2 }
        return 3
    }

    private func waitUntilStarted(
        _ states: AsyncStream<DeviceSessionState>,
        timeout: Duration
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await state in states {
                    try Task.checkCancellation()
                    if state == .started { return }
                    if state == .stopped {
                        throw AWLError.device(
                            "Meta DAT session stopped before reaching started"
                        )
                    }
                }
                throw AWLError.device(
                    "Meta DAT session state stream ended before reaching started"
                )
            }

            group.addTask {
                try await Task.sleep(for: timeout)
                throw AWLError.device(
                    "Meta DAT session did not reach started before timeout"
                )
            }

            _ = try await group.next()
            group.cancelAll()
        }
    }

    public func disconnect() async {
        stopping = true
        tearDownSession()
    }

    private func handleUnexpectedStop() {
        guard !stopping else { return }
        eventContinuation?.yield(
            .failed(nil, .device("Meta DAT device session stopped"))
        )
        tearDownSession()
    }

    private func handleRegistrationLoss() {
        guard !stopping, deviceSession != nil else { return }
        eventContinuation?.yield(
            .failed(nil, .device("Meta DAT registration became unavailable"))
        )
        tearDownSession()
    }

    private func emitDeviceError(_ message: String) {
        guard !stopping else { return }
        eventContinuation?.yield(.failed(nil, .device(message)))
    }

    private func tearDownSession() {
        stateTask?.cancel()
        errorTask?.cancel()
        registrationTask?.cancel()
        deviceMonitorTask?.cancel()
        selectedDeviceListenerTask?.cancel()
        stateTask = nil
        errorTask = nil
        registrationTask = nil
        deviceMonitorTask = nil
        selectedDeviceListenerTask = nil

        deviceSession?.stop()
        deviceSession = nil
        stopping = false
    }
}
