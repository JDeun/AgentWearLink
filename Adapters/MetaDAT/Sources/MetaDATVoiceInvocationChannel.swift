import AgentWearLinkCore
import Foundation
import MWDATCore

/// Host-started Voice Invocation ownership independent of DeviceSession.
///
/// Registration and available-device changes select a connected, compatible
/// glasses device. Every listener lease is fenced: a delayed acknowledgement
/// or vendor callback from an old device cannot enter a newer generation.
@MainActor
public final class MetaDATVoiceInvocationChannel {
    private let wearables: any WearablesInterface
    private let listener: MetaDATVoiceInvocationListener
    private let reopenPolicy: MetaDATVoiceReopenPolicy
    // A bounded re-snapshot covers pairing/compatibility/link changes that
    // do not always emit a fresh devicesStream event in the pinned SDK.
    private let eligibilityPolicy = MetaDATVoiceReopenPolicy(delays: [
        .milliseconds(250), .milliseconds(500), .seconds(1),
        .seconds(2), .seconds(4), .seconds(8)
    ])
    private let diagnostics: AWLDiagnosticRecorder?
    private let onEvent: @Sendable (InteractionEvent) -> Void
    private let onReadiness: @Sendable (Bool) -> Void

    private var running = false
    private var selectedIdentifier: DeviceIdentifier?
    private var selectedLinkToken: (any AnyListenerToken)?
    private var listeningLease: UInt64?
    private var leaseGeneration: UInt64 = 0
    private var failures = 0
    private var registrationTask: Task<Void, Never>?
    private var devicesTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var eligibilityRetryTask: Task<Void, Never>?
    private var eligibilityRetries = 0

    public init(
        wearables: any WearablesInterface = Wearables.shared,
        reopenPolicy: MetaDATVoiceReopenPolicy = .init(),
        diagnostics: AWLDiagnosticRecorder? = nil,
        onEvent: @escaping @Sendable (InteractionEvent) -> Void,
        onReadiness: @escaping @Sendable (Bool) -> Void
    ) {
        self.wearables = wearables
        self.listener = MetaDATVoiceInvocationListener(wearables: wearables)
        self.reopenPolicy = reopenPolicy
        self.diagnostics = diagnostics
        self.onEvent = onEvent
        self.onReadiness = onReadiness
    }

    public func start() {
        guard !running else { return }
        running = true
        failures = 0
        eligibilityRetries = 0

        // Subscribe before first reconciliation; changes during an initial
        // registration or device snapshot cannot be lost.
        let registrationStates = wearables.registrationStateStream()
        registrationTask = Task { [weak self] in
            for await _ in registrationStates {
                guard !Task.isCancelled else { return }
                self?.reconcile()
            }
        }

        let devices = wearables.devicesStream()
        devicesTask = Task { [weak self] in
            for await _ in devices {
                guard !Task.isCancelled else { return }
                self?.reconcile()
            }
        }

        reconcile()
    }

    public func stop() {
        running = false
        registrationTask?.cancel()
        devicesTask?.cancel()
        registrationTask = nil
        devicesTask = nil
        cancelEligibilityRetry(resetBudget: true)
        retireSelection()
    }

    private func cancelEligibilityRetry(resetBudget: Bool) {
        eligibilityRetryTask?.cancel()
        eligibilityRetryTask = nil
        if resetBudget { eligibilityRetries = 0 }
    }

    private func scheduleEligibilityRetry() {
        guard running, eligibilityRetryTask == nil else { return }
        let attempt = eligibilityRetries
        guard let delay = eligibilityPolicy.delay(afterFailure: attempt) else {
            diagnostics?.record(.init(kind: .metaVoiceEligibilityRetryExhausted))
            return
        }
        eligibilityRetries += 1
        eligibilityRetryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.eligibilityRetryTask = nil
            self?.reconcile()
        }
    }

    private func retireSelection() {
        retireListener()
        selectedIdentifier = nil
        if let selectedLinkToken {
            Task { await selectedLinkToken.cancel() }
        }
        selectedLinkToken = nil
        failures = 0
    }

    private func retireListener() {
        leaseGeneration &+= 1
        listeningLease = nil
        retryTask?.cancel()
        retryTask = nil
        listener.stop()
        onReadiness(false)
    }

    private func reconcile() {
        guard running else { return }
        guard case .registered = wearables.registrationState else {
            cancelEligibilityRetry(resetBudget: true)
            retireSelection()
            return
        }

        let candidates = wearables.devices.compactMap { identifier
            -> (identifier: DeviceIdentifier, rank: Int)? in
            guard let device = wearables.deviceForIdentifier(identifier),
                  device.compatibility() == .compatible else {
                return nil
            }
            let rank: Int
            if device.linkState == .connected && device.donState == .donned {
                rank = 0
            } else if device.linkState == .connected {
                rank = 1
            } else {
                rank = 2
            }
            return (identifier: identifier, rank: rank)
        }
        let chosen = candidates.min {
            if $0.rank == $1.rank {
                return $0.identifier < $1.identifier
            }
            return $0.rank < $1.rank
        }?.identifier

        if chosen != selectedIdentifier {
            cancelEligibilityRetry(resetBudget: true)
            retireSelection()
            selectedIdentifier = chosen
            if let chosen,
               let device = wearables.deviceForIdentifier(chosen) {
                // Device lists need not change when an already-paired pair
                // disconnects/reconnects. Observe that link independently.
                selectedLinkToken = device.addLinkStateListener { [weak self] _ in
                    Task { @MainActor [weak self] in self?.reconcile() }
                }
            }
        }

        guard let chosen,
              let device = wearables.deviceForIdentifier(chosen),
              device.linkState == .connected else {
            if listeningLease != nil { retireListener() }
            diagnostics?.record(.init(
                kind: chosen == nil ? .metaVoiceNoEligibleDevice : .metaVoiceAwaitingLink
            ))
            scheduleEligibilityRetry()
            return
        }
        // The candidate became eligible. Retire any in-flight snapshot timer;
        // the independent listener retry budget is unchanged.
        cancelEligibilityRetry(resetBudget: true)

        guard listeningLease == nil, retryTask == nil else { return }
        // Once bounded reopen attempts have been exhausted, incidental
        // device-list notifications must not bypass the retry budget.
        // A new device selection or explicit stop/start resets this counter.
        guard failures <= reopenPolicy.delays.count else { return }

        leaseGeneration &+= 1
        let lease = leaseGeneration
        listeningLease = lease

        do {
            try listener.listen(
                deviceIdentifier: chosen,
                onInvocation: { [weak self] invocation in
                    Task { @MainActor [weak self] in
                        await self?.receive(invocation, lease: lease)
                    }
                },
                onError: { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.diagnostics?.record(.init(kind: .metaVoiceChannelError))
                        self?.handleFailure(lease: lease)
                    }
                }
            )
            diagnostics?.record(.init(kind: .metaVoiceListenerStarted))
            onReadiness(true)
        } catch let error as VoiceInvocationError {
            switch error {
            case .deviceNotFound:
                diagnostics?.record(.init(kind: .metaVoiceDeviceNotFound))
            case .channelNotConnected:
                diagnostics?.record(.init(kind: .metaVoiceChannelNotConnected))
            case .invalidWearablesInterface:
                diagnostics?.record(.init(kind: .metaVoiceInterfaceInvalid))
            default:
                diagnostics?.record(.init(kind: .metaVoiceListenerFailed))
            }
            handleFailure(lease: lease)
        } catch {
            diagnostics?.record(.init(kind: .metaVoiceListenerFailed))
            handleFailure(lease: lease)
        }
    }

    private func receive(_ invocation: any VoiceInvocation, lease: UInt64) async {
        guard running, listeningLease == lease else { return }

        // The Meta AI response handle is answered BEFORE the invocation is
        // forwarded to Core/agent. A refused acknowledgement emits failure.
        let acknowledged = await MetaDATVoiceInvocationAcknowledger.acknowledge(
            invocation
        )
        guard running, listeningLease == lease, let acknowledged else {
            return
        }
        onEvent(acknowledged)
    }

    private func handleFailure(lease: UInt64) {
        guard running, listeningLease == lease else { return }
        retireListener()
        let attempt = failures
        failures += 1
        guard let delay = reopenPolicy.delay(afterFailure: attempt) else {
            diagnostics?.record(.init(kind: .metaVoiceRetryExhausted))
            // Exhausted for this selection. A new registration/device
            // selection, or an explicit stop/start, is the recovery boundary.
            return
        }
        retryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.retryTask = nil
            self?.reconcile()
        }
    }
}
