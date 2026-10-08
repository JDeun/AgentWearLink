/// Admission policy for *post-acknowledgement* Voice Invocation -> DAT
/// media handoff. No SDK media surface is acquired until the app is foreground,
/// the caller opted in, and no previous connection is owned or starting.
enum MetaDATVoiceMediaActivationPolicy {
    static func mayActivate(
        optedIn: Bool,
        foreground: Bool,
        connecting: Bool,
        sessionActive: Bool,
        stopping: Bool
    ) -> Bool {
        optedIn && foreground && !connecting && !sessionActive && !stopping
    }
}
