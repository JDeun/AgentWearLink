import Foundation
import AgentWearLinkCore
import MWDATCore

struct MetaDATDeviceSelectionCandidate: Equatable, Sendable {
    let identifier: String
    let rank: Int
}

enum MetaDATDeviceSelectionPolicy {
    static func selectedIdentifier(
        from candidates: [MetaDATDeviceSelectionCandidate]
    ) -> String? {
        candidates.min { lhs, rhs in
            if lhs.rank != rhs.rank {
                return lhs.rank < rhs.rank
            }
            return lhs.identifier < rhs.identifier
        }?.identifier
    }
}

struct MetaDATSessionGenerationFence: Sendable {
    private(set) var current: UInt64 = 0

    mutating func begin() -> UInt64 {
        current &+= 1
        return current
    }

    func owns(_ generation: UInt64) -> Bool {
        current == generation
    }

    @discardableResult
    mutating func retire(ifOwned generation: UInt64? = nil) -> Bool {
        if let generation, generation != current {
            return false
        }
        current &+= 1
        return true
    }
}

final class MetaDATDeviceEventSource: @unchecked Sendable {
    private struct Subscription {
        let generation: UInt64
        let continuation: AsyncStream<InteractionEvent>.Continuation
    }

    private let lock = NSLock()
    private let bufferLimit: Int
    private var nextGeneration: UInt64 = 0
    private var subscription: Subscription?

    init(bufferLimit: Int) {
        precondition(bufferLimit > 0)
        self.bufferLimit = bufferLimit
    }

    func stream() -> AsyncStream<InteractionEvent> {
        AsyncStream(
            bufferingPolicy: .bufferingNewest(bufferLimit)
        ) { continuation in
            lock.lock()
            nextGeneration &+= 1
            let generation = nextGeneration
            let previous = subscription
            subscription = Subscription(
                generation: generation,
                continuation: continuation
            )
            lock.unlock()

            continuation.onTermination = { [weak self] _ in
                self?.remove(generation: generation)
            }
            previous?.continuation.finish()
        }
    }

    func yield(_ event: InteractionEvent) {
        lock.lock()
        let active = subscription
        lock.unlock()

        guard let active else { return }

        switch active.continuation.yield(event) {
        case .enqueued:
            break
        case .dropped:
            _ = active.continuation.yield(
                .failed(
                    event.interactionID,
                    .overloaded("Meta DAT device event buffer capacity exceeded")
                )
            )
            retire(generation: active.generation)
        case .terminated:
            remove(generation: active.generation)
        @unknown default:
            retire(generation: active.generation)
        }
    }

    private func retire(generation: UInt64) {
        let continuation: AsyncStream<InteractionEvent>.Continuation?

        lock.lock()
        if subscription?.generation == generation {
            continuation = subscription?.continuation
            subscription = nil
        } else {
            continuation = nil
        }
        lock.unlock()

        continuation?.finish()
    }

    private func remove(generation: UInt64) {
        lock.lock()
        if subscription?.generation == generation {
            subscription = nil
        }
        lock.unlock()
    }
}

/// First concrete device adapter for Meta Wearables DAT.
///
/// This target is intentionally iOS/vendor-specific and must be compiled only
/// from an iOS reference app that links MWDATCore. The root AWL Core package
/// does not depend on Meta DAT.
public actor MetaDATDeviceAdapter: DeviceAdapter {
    public static let defaultEventBufferLimit = 64

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
    private nonisolated let eventSource: MetaDATDeviceEventSource
    private var generationFence = MetaDATSessionGenerationFence()
    private var connecting = false
    private var stopping = false
    private let connectTimeout: Duration

    public init(
        wearables: any WearablesInterface = Wearables.shared,
        connectTimeout: Duration = .seconds(15),
        eventBufferLimit: Int = MetaDATDeviceAdapter.defaultEventBufferLimit
    ) {
        precondition(connectTimeout > .zero)
        precondition(eventBufferLimit > 0)
        self.wearables = wearables
        self.connectTimeout = connectTimeout
        self.eventSource = MetaDATDeviceEventSource(bufferLimit: eventBufferLimit)
    }

    public nonisolated func events() -> AsyncStream<InteractionEvent> {
        eventSource.stream()
    }

    public func connect() async throws {
        guard deviceSession == nil, !connecting else { return }

        stopping = false
        connecting = true
        let generation = generationFence.begin()
        defer {
            if generationFence.owns(generation) {
                connecting = false
            }
        }

        guard case .registered = wearables.registrationState else {
            tearDownSession(expectedGeneration: generation)
            throw AWLError.device("Meta DAT application is not registered")
        }

        registrationTask = Task { [weak self] in
            for await state in wearables.registrationStateStream() {
                guard !Task.isCancelled else { break }
                guard case .registered = state else {
                    await self?.handleRegistrationLoss(generation: generation)
                    break
                }
            }
        }

        let devices = wearables.devices.compactMap {
            self.wearables.deviceForIdentifier($0)
        }
        let selectionCandidates = devices.map {
            MetaDATDeviceSelectionCandidate(
                identifier: $0.identifier,
                rank: Self.deviceRank($0)
            )
        }
        guard let selectedIdentifier = MetaDATDeviceSelectionPolicy.selectedIdentifier(
            from: selectionCandidates
        ),
        let selectedDevice = devices.first(where: { $0.identifier == selectedIdentifier }) else {
            tearDownSession(expectedGeneration: generation)
            throw AWLError.device("Meta DAT has no paired device eligible for session selection")
        }
        guard selectedDevice.compatibility() == .compatible else {
            tearDownSession(expectedGeneration: generation)
            throw AWLError.device("Selected Meta DAT device is not SDK-compatible")
        }

        selectedDeviceListenerTask = Task { [weak self] in
            await self?.monitorSelectedDeviceSignals(
                selectedDevice,
                generation: generation
            )
        }
        deviceMonitorTask = Task { [weak self] in
            await self?.monitorSelectedDevice(
                selectedIdentifier,
                generation: generation
            )
        }

        let selector = SpecificDeviceSelector(device: selectedIdentifier)
        let session: DeviceSession
        do {
            session = try wearables.createSession(deviceSelector: selector)
        } catch {
            tearDownSession(expectedGeneration: generation)
            throw error
        }

        guard generationFence.owns(generation), !stopping else {
            throw AWLError.device("Meta DAT session setup was superseded")
        }
        deviceSession = session

        // Obtain the streams before start() so initial state/error transitions
        // cannot be missed. Meta's current samples use the same ordering.
        let stateStream = session.stateStream()
        let errorStream = session.errorStream()

        errorTask = Task { [weak self] in
            for await error in errorStream {
                guard !Task.isCancelled else { break }
                await self?.emitDeviceError(
                    error.localizedDescription,
                    generation: generation
                )
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
            guard generationFence.owns(generation), !stopping else {
                throw AWLError.device("Meta DAT session setup was superseded")
            }

            stateTask = Task { [weak self] in
                for await state in stateStream {
                    guard !Task.isCancelled else { break }

                    if state == .stopped {
                        await self?.handleUnexpectedStop(generation: generation)
                        break
                    }
                }
            }
        } catch {
            // A stale connect continuation must never tear down a newer retry.
            tearDownSession(expectedGeneration: generation)
            throw error
        }
    }

    private func monitorSelectedDeviceSignals(
        _ device: Device,
        generation: UInt64
    ) async {
        let linkToken = device.addLinkStateListener { [weak self] state in
            guard state != .connected else { return }
            Task { await self?.handleSelectedDeviceUnavailable(
                "Selected Meta DAT device link became unavailable: \(state)",
                generation: generation
            ) }
        }
        let compatibilityToken = device.addCompatibilityListener { [weak self] compatibility in
            guard compatibility != .compatible else { return }
            Task { await self?.handleSelectedDeviceUnavailable(
                "Selected Meta DAT device became incompatible: \(compatibility)",
                generation: generation
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

    private func monitorSelectedDevice(
        _ selectedIdentifier: DeviceIdentifier,
        generation: UInt64
    ) async {
        for await identifiers in wearables.devicesStream() {
            guard !Task.isCancelled else { break }
            guard identifiers.contains(selectedIdentifier),
                  let device = wearables.deviceForIdentifier(selectedIdentifier) else {
                handleSelectedDeviceUnavailable(
                    "Selected Meta DAT device is no longer paired/available",
                    generation: generation
                )
                return
            }

            let compatibility = device.compatibility()
            guard compatibility == .compatible else {
                handleSelectedDeviceUnavailable(
                    "Selected Meta DAT device became incompatible: \(compatibility)",
                    generation: generation
                )
                return
            }
        }
    }

    private func handleSelectedDeviceUnavailable(
        _ message: String,
        generation: UInt64
    ) {
        guard !stopping,
              generationFence.owns(generation),
              deviceSession != nil else {
            return
        }
        yieldEvent(.failed(nil, .device(message)))
        tearDownSession(expectedGeneration: generation)
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

    private func handleUnexpectedStop(generation: UInt64) {
        guard !stopping, generationFence.owns(generation) else { return }
        yieldEvent(
            .failed(nil, .device("Meta DAT device session stopped"))
        )
        tearDownSession(expectedGeneration: generation)
    }

    private func handleRegistrationLoss(generation: UInt64) {
        guard !stopping, generationFence.owns(generation) else { return }

        // Registration ownership begins before DeviceSession creation. Do not
        // require deviceSession != nil here: revocation during startup must
        // invalidate the whole connect generation.
        yieldEvent(
            .failed(nil, .device("Meta DAT registration became unavailable"))
        )
        tearDownSession(expectedGeneration: generation)
    }

    private func emitDeviceError(_ message: String, generation: UInt64) {
        guard !stopping, generationFence.owns(generation) else { return }
        yieldEvent(.failed(nil, .device(message)))
    }

    private func yieldEvent(_ event: InteractionEvent) {
        eventSource.yield(event)
    }

    private func tearDownSession(expectedGeneration: UInt64? = nil) {
        guard generationFence.retire(ifOwned: expectedGeneration) else {
            return
        }

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
        connecting = false
        stopping = false
    }
}
