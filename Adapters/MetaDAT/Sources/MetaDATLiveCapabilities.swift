import AgentWearLinkCore
public struct MetaDATLiveCapabilities: Sendable, Equatable {
    public var sessionReady=false; public var speechReady=false; public var cameraReady=false; public var voiceInvocationReady=false
    public init() {}
    public var value: CapabilitySet { guard sessionReady else { return [] }; var r: CapabilitySet=[.textInput,.textOutput,.speakerOutput]; if speechReady { r.insert(.speechInput) }; if cameraReady { r.insert(.cameraSnapshot) }; if voiceInvocationReady { r.insert(.voiceInvocation) }; return r }
}
