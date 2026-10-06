import Foundation

/// An intentional, bounded still image captured for a single interaction.
///
/// Core owns only the transport-safe value. Device adapters remain responsible
/// for obtaining user-authorized media and must not continuously stream camera
/// frames through this type.
public struct ImageAttachment: Sendable, Equatable {
    public enum Format: String, Sendable, Equatable, Codable {
        case jpeg
        case png
    }

    public static let defaultMaximumBytes = 5 * 1024 * 1024

    public let data: Data
    public let format: Format

    public init(
        data: Data,
        format: Format,
        maximumBytes: Int = ImageAttachment.defaultMaximumBytes
    ) throws {
        guard maximumBytes > 0, data.count <= maximumBytes else {
            throw AWLError.capabilityUnavailable("image payload exceeds configured limit")
        }
        self.data = data
        self.format = format
    }
}

public struct VisionRequest: Sendable, Equatable {
    public let interactionID: InteractionID
    public let prompt: String
    public let image: ImageAttachment

    public init(interactionID: InteractionID, prompt: String, image: ImageAttachment) {
        self.interactionID = interactionID
        self.prompt = prompt
        self.image = image
    }
}

/// Optional device-side extension for explicit still-image capture.
public protocol SnapshotCapturingDevice: DeviceAdapter {
    func captureSnapshot(interactionID: InteractionID) async throws -> ImageAttachment
}

/// Optional agent-side extension for image-aware requests.
public protocol VisionAgentAdapter: AgentAdapter {
    func responses(for request: VisionRequest) async -> AsyncThrowingStream<AgentResponse, Error>
}
