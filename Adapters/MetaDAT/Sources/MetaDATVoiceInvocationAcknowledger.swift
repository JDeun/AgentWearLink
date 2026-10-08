import AgentWearLinkCore
import MWDATCore

/// Acknowledges supported Meta AI invocations before exposing them to agent work.
/// Channel registration/reopen are owned by #144/#146.
public enum MetaDATVoiceInvocationAcknowledger {
    public static func acknowledge(_ invocation: any VoiceInvocation) async -> InteractionEvent? {
        guard let launch = invocation as? LaunchApp else {
            return nil
        }
        let id = InteractionID()
        let delivered = await launch.responseHandle.sendSuccess(actionOutput: nil)
        return outcome(acknowledged: delivered, interactionID: id)
    }

    /// An acknowledgement failure belongs to one invocation, not to the
    /// device session. ID-less AWLError.device is a terminal runtime failure.
    /// Keep acknowledgement failures scoped so an intermittent Meta AI
    /// response-handle refusal cannot disconnect unrelated agent work.
    static func outcome(
        acknowledged: Bool,
        interactionID: InteractionID
    ) -> InteractionEvent {
        if acknowledged {
            return .invocation(interactionID, nil)
        }
        return .failed(
            interactionID,
            .device("Meta voice invocation acknowledgement was not delivered")
        )
    }
}
