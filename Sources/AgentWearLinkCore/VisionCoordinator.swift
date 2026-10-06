import Foundation

/// Coordinates one explicit still-image request.
///
/// This type deliberately requires opt-in vision protocols on both sides,
/// preventing an ordinary text-only runtime from acquiring camera media.
public struct VisionCoordinator: Sendable {
    private let device: any SnapshotCapturingDevice
    private let agent: any VisionAgentAdapter

    public init(device: any SnapshotCapturingDevice, agent: any VisionAgentAdapter) {
        self.device = device
        self.agent = agent
    }

    public func responses(
        interactionID: InteractionID,
        prompt: String
    ) async throws -> AsyncThrowingStream<AgentResponse, Error> {
        guard device.capabilities.contains(.cameraSnapshot) else {
            throw AWLError.capabilityUnavailable("device does not support camera snapshots")
        }
        guard agent.supportsVisionInput else {
            throw AWLError.capabilityUnavailable("agent does not support image input")
        }

        let image = try await device.captureSnapshot(interactionID: interactionID)

        // Capture implementations are allowed to be cancellation-insensitive. Re-check
        // here so private media is never handed to the agent after the interaction was
        // cancelled while capture was still completing.
        try Task.checkCancellation()

        return await agent.responses(
            for: VisionRequest(interactionID: interactionID, prompt: prompt, image: image)
        )
    }
}
