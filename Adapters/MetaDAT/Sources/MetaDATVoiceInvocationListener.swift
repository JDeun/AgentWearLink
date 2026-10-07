import Foundation
import AgentWearLinkCore
import MWDATCore

/// Owns one VoiceInvocationsStream lease and its listener tokens. Invocation
/// acknowledgement/policy is deliberately left to the next slice (#145).
@MainActor
public final class MetaDATVoiceInvocationListener {
    private let wearables: any WearablesInterface
    private let generation = MetaDATListenerGeneration()
    private var stream: VoiceInvocationsStream?
    private var invocationToken: (any AnyListenerToken)?
    private var errorToken: (any AnyListenerToken)?

    public init(wearables: any WearablesInterface = Wearables.shared) {
        self.wearables = wearables
    }

    public func listen(
        deviceIdentifier: DeviceIdentifier,
        onInvocation: @escaping @Sendable (any VoiceInvocation) -> Void,
        onError: @escaping @Sendable (VoiceInvocationError) -> Void
    ) throws {
        stop()
        guard case .registered = wearables.registrationState else {
            throw AWLError.device("Meta DAT application is not registered")
        }

        let listenerGeneration = generation.begin()
        let gate = generation
        let stream = try VoiceInvocationsStream(wearables: wearables)
        let invocationToken = stream.invocationsPublisher.listen { invocation in
            guard gate.isCurrent(listenerGeneration) else { return }
            onInvocation(invocation)
        }
        let errorToken = stream.errorPublisher.listen { error in
            guard gate.isCurrent(listenerGeneration) else { return }
            onError(error)
        }

        self.invocationToken = invocationToken
        self.errorToken = errorToken

        do {
            try stream.start(deviceIdentifier: deviceIdentifier)
            self.stream = stream
        } catch {
            generation.invalidate()
            self.invocationToken = nil
            self.errorToken = nil
            stream.stop()
            Task {
                await invocationToken.cancel()
                await errorToken.cancel()
            }
            throw error
        }
    }

    public func stop() {
        generation.invalidate()

        stream?.stop()
        stream = nil

        let invocationToken = invocationToken
        let errorToken = errorToken
        self.invocationToken = nil
        self.errorToken = nil

        Task {
            if let invocationToken {
                await invocationToken.cancel()
            }
            if let errorToken {
                await errorToken.cancel()
            }
        }
    }
}
