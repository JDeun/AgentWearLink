import AgentWearLinkCore

/// Computes advertised Meta capabilities only from currently usable paths.
/// Static SDK support alone never advertises a capability.
public struct MetaDATLiveCapabilities: Sendable, Equatable {
    public var sessionReady = false
    public var speechReady = false
    public var cameraReady = false
    public var voiceInvocationReady = false

    public init() {}

    public var value: CapabilitySet {
        guard sessionReady else { return [] }
        var result: CapabilitySet = [.textInput, .textOutput, .speakerOutput]
        if speechReady { result.insert(.speechInput) }
        if cameraReady { result.insert(.cameraSnapshot) }
        if voiceInvocationReady { result.insert(.voiceInvocation) }
        return result
    }
}
