import AgentWearLinkCore
import MWDATCore

/// Acknowledges supported Meta AI invocations before exposing them to agent work.
/// Channel registration/reopen are owned by #144/#146.
public enum MetaDATVoiceInvocationAcknowledger {
    public static func acknowledge(_ invocation: any VoiceInvocation) async -> InteractionEvent? {
        guard let launch = invocation as? LaunchApp else {
            return nil
        }
        guard await launch.responseHandle.sendSuccess(actionOutput: nil) else {
            return .failed(nil, .device("Meta voice invocation acknowledgement was not delivered"))
        }
        return .invocation(InteractionID(), nil)
    }
}
