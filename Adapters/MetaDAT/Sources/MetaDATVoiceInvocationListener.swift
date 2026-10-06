import Foundation
import AgentWearLinkCore
import MWDATCore

/// Owns one VoiceInvocationsStream lease and its listener tokens. Invocation
/// acknowledgement/policy is deliberately left to the next slice (#145).
@MainActor
public final class MetaDATVoiceInvocationListener {
    private let wearables: any WearablesInterface
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

        let stream = try VoiceInvocationsStream(wearables: wearables)
        invocationToken = stream.invocationsPublisher.listen(onInvocation)
        errorToken = stream.errorPublisher.listen(onError)
        try stream.start(deviceIdentifier: deviceIdentifier)
        self.stream = stream
    }

    public func stop() {
        stream?.stop()
        stream = nil
        let invocationToken = invocationToken
        let errorToken = errorToken
        self.invocationToken = nil
        self.errorToken = nil
        if let invocationToken { Task { await invocationToken.cancel() } }
        if let errorToken { Task { await errorToken.cancel() } }
    }
}
