import AgentWearLinkCore

/// Production device projection for an opt-in hands-free wake workflow.
/// LaunchApp is acknowledged by the independent Voice Invocation channel
/// before any media work; the concrete vendor session/Speech can only start
/// after the app is foreground and the acknowledged launch event is emitted.
///
/// The launch event contains no dictated phrase. Once the session is ready,
/// DAT Speech emits a later final transcript to the same Core event stream.
public actor MetaDATVoiceWakeDeviceAdapter: DeviceAdapter {
    private let vendor: MetaDATDeviceAdapter

    public init(vendor: MetaDATDeviceAdapter) {
        self.vendor = vendor
    }

    public nonisolated var capabilities: CapabilitySet {
        Self.exposedCapabilities(vendor.capabilities)
    }

    /// Core sees only surfaces that this DeviceAdapter projection implements.
    /// Foreground Speech is available after handoff, but the wake wrapper is
    /// not a SnapshotCapturingDevice and must not advertise camera snapshots.
    nonisolated static func exposedCapabilities(
        _ available: CapabilitySet
    ) -> CapabilitySet {
        available.intersection([.voiceInvocation, .speechInput])
    }

    public nonisolated func events() -> AsyncStream<InteractionEvent> {
        vendor.events()
    }

    public func connect() async throws {
        try Task.checkCancellation()
        await vendor.setForegroundMediaActivationOnVoiceLaunch(true)
        await vendor.startVoiceInvocationListening()
        try Task.checkCancellation()
    }

    public func disconnect() async {
        // Stops both modes. In particular a late activation cannot continue
        // using a retired Voice Invocation ownership boundary.
        await vendor.stopVoiceInvocationListening()
        await vendor.disconnect()
    }
}
