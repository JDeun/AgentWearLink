import AgentWearLinkCore

/// A Speech channel failure has no interaction ID because transcripts may
/// arrive outside an active turn, but it must not be misclassified as a
/// terminal device-session failure by AgentWearLinkRuntime.
enum MetaDATSpeechFailurePolicy {
    static func event(for error: any Error) -> InteractionEvent {
        if let failure = error as? MetaDATSpeechDeliveryError,
           failure == .finalTranscriptOverflow {
            return .failed(nil, .capabilityUnavailable(
                "Meta DAT Speech final transcript delivery capacity exceeded"
            ))
        }
        return .failed(nil, .capabilityUnavailable(
            MetaDATVendorFailurePolicy.message(for: error, surface: .speech)
        ))
    }
}
