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

    public init(wearables: any WearablesInterface = Wearables.shared) {
        self.wearables = wearables
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

        let selector = AutoDeviceSelector(wearables: wearables)
        let session = try wearables.createSession(deviceSelector: selector)
        deviceSession = session

        errorTask = Task { [weak self] in
            for await error in session.errorStream() {
                guard !Task.isCancelled else { break }
                await self?.emitDeviceError(error.localizedDescription)
            }
        }

        do {
            try session.start()

            var reachedStarted = false
            for await state in session.stateStream() {
                if state == .started {
                    reachedStarted = true
                    break
                }

                if state == .stopped {
                    break
                }
            }

            guard reachedStarted else {
                throw AWLError.device(
                    "Meta DAT session stopped before reaching started"
                )
            }

            stateTask = Task { [weak self] in
                for await state in session.stateStream() {
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
