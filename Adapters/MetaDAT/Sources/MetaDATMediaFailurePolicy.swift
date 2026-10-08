import AgentWearLinkCore

/// Session-owned media failure must not retire a separately active Voice
/// Invocation channel. Core reserves ID-less AWLError.device for terminating
/// *all* device work; an opt-in post-ack Speech/media failure is local.
enum MetaDATMediaFailurePolicy {
    static func event(
        _ message: String,
        preserveIndependentVoice: Bool
    ) -> InteractionEvent {
        if preserveIndependentVoice {
            return .failed(nil, .capabilityUnavailable(message))
        }
        return .failed(nil, .device(message))
    }
}
