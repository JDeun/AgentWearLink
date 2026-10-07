import AgentWearLinkCore

public struct MetaDATLiveCapabilities: Sendable, Equatable {
    public var sessionReady = false
    public var speechReady = false
    public var cameraReady = false
    public var voiceInvocationReady = false

    public init() {}

    public var value: CapabilitySet {
        guard sessionReady else { return [] }

        // MetaDATDeviceAdapter is currently an input/capture adapter. Native
        // iPhone text/TTS output is composed independently through the host
        // InteractionOutputSink and must not be advertised as a device command.
        var result: CapabilitySet = [.textInput]
        if speechReady { result.insert(.speechInput) }
        if cameraReady { result.insert(.cameraSnapshot) }
        if voiceInvocationReady { result.insert(.voiceInvocation) }
        return result
    }
}
