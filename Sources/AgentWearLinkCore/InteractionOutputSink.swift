/// Typed host-side sink for normalized AgentWearLink interaction output.
///
/// Output rendering belongs to the host/application layer rather than
/// `DeviceAdapter`: a wearable input adapter is not required to own phone
/// speakers, UI text, or other response surfaces.
public protocol InteractionOutputSink: Sendable {
    func consume(_ event: InteractionEvent) async
}
