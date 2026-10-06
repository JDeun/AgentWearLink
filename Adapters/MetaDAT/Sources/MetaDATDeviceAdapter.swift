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

        let devices = wearables.devices.compactMap {
            wearables.deviceForIdentifier($0)
        }
        guard let selectedDevice = devices.min(by: {
            Self.deviceRank($0) < Self.deviceRank($1)
        }) else {
            throw AWLError.device("Meta DAT has no paired device eligible for session selection")
        }
        guard selectedDevice.compatibility() == .compatible else {
            throw AWLError.device("Selected Meta DAT device is not SDK-compatible")
        }

        // Use a concrete identifier instead of AutoDeviceSelector. Meta's current
        // sample notes that the auto selector is populated asynchronously and can
        // be empty during a cold-start session request.
        let selector = SpecificDeviceSelector(device: selectedDevice.identifier)
        let session = try wearables.createSession(deviceSelector: selector)
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
            await tearDownSession()
            throw error
        }
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
        guard deviceSession != nil else { return }
        stopping = true
        await tearDownSession()
    }

    private func handleUnexpectedStop() {
        guard !stopping else { return }
        eventContinuation?.yield(
            .failed(nil, .device("Meta DAT device session stopped"))
        )
        deviceSession = nil
        stateTask = nil
        errorTask?.cancel()
        errorTask = nil
    }

    private func emitDeviceError(_ message: String) {
        guard !stopping else { return }
        eventContinuation?.yield(.failed(nil, .device(message)))
    }

    private func tearDownSession() {
        stateTask?.cancel()
        errorTask?.cancel()
        stateTask = nil
        errorTask = nil

        deviceSession?.stop()
        deviceSession = nil
        stopping = false
    }
}
