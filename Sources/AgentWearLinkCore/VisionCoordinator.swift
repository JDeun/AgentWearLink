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

        let image = try await device.captureSnapshot(interactionID: interactionID)
        return await agent.responses(
            for: VisionRequest(interactionID: interactionID, prompt: prompt, image: image)
        )
    }
}
