/// Captures the stream ownership that existed before a one-shot photo flow.
/// Restoration is computed, not performed here, so every terminal path can use
/// the same rule without retaining SDK objects.
public struct MetaDATPriorStreamState: Sendable, Equatable {
    public let wasStreaming: Bool
    public let carriedAudio: Bool
    public init(wasStreaming: Bool, carriedAudio: Bool) {
        self.wasStreaming = wasStreaming
        self.carriedAudio = carriedAudio
    }

    public var shouldResumeVideo: Bool { wasStreaming }
    public var shouldResumeAudio: Bool { wasStreaming && carriedAudio }
}
