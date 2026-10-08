import AgentWearLinkCore

/// DeviceAdapter projection for Voice Invocation-only operation. This has no
/// DeviceSession, Speech or Camera lifecycle: a registered Meta AI launch can
/// reach the production OpenClaw Core runtime while media is unavailable.
///
/// A separate media-mode reference host must explicitly opt in to
/// MetaDATDeviceAdapter.connect() when photos/transcripts are needed.
public actor MetaDATVoiceOnlyDeviceAdapter: DeviceAdapter {
    private let vendor: MetaDATDeviceAdapter

    public init(vendor: MetaDATDeviceAdapter) {
        self.vendor = vendor
    }

    public nonisolated var capabilities: CapabilitySet {
        Self.voiceOnlyCapabilities(vendor.capabilities)
    }

    public nonisolated func events() -> AsyncStream<InteractionEvent> {
        vendor.events()
    }

    public func connect() async throws {
        try Task.checkCancellation()
        await vendor.startVoiceInvocationListening()
        try Task.checkCancellation()
    }

    public func disconnect() async {
        await vendor.stopVoiceInvocationListening()
    }

    public nonisolated static func voiceOnlyCapabilities(
        _ available: CapabilitySet
    ) -> CapabilitySet {
        available.intersection(.voiceInvocation)
    }
}
