public struct CapabilitySet: OptionSet, Sendable, Equatable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let textInput       = Self(rawValue: 1 << 0)
    public static let speechInput     = Self(rawValue: 1 << 1)
    public static let rawAudioInput   = Self(rawValue: 1 << 2)
    public static let cameraSnapshot  = Self(rawValue: 1 << 3)
    public static let speakerOutput   = Self(rawValue: 1 << 4)
    public static let textOutput      = Self(rawValue: 1 << 5)
    public static let voiceInvocation = Self(rawValue: 1 << 6)
}
