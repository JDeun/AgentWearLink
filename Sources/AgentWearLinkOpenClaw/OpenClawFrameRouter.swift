import Foundation

public enum OpenClawInboundFrame: Sendable, Equatable {
    case response(OpenClawResponseEnvelope)
    case event(OpenClawEventEnvelope)
}

public enum OpenClawFrameError: Error, Sendable, Equatable {
    case oversizedPreAuthFrame(actual: Int, maximum: Int)
    case oversizedInboundFrame(actual: Int, maximum: Int)
    case malformedFrame
    case unsupportedFrameType(String)
}

/// Validates frame-size ceilings before JSON decoding and decodes each inbound frame once.
/// The post-auth ceiling is intentionally independent of Gateway `maxPayload`: the
/// protocol does not guarantee that the outbound payload limit is symmetric for inbound frames.
public struct OpenClawFrameRouter: Sendable {
    public static let defaultInboundMaximumBytes = 25 * 1024 * 1024
    private struct Envelope: Decodable {
        let frame: OpenClawInboundFrame

        private enum CodingKeys: String, CodingKey { case type }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)

            switch type {
            case "res":
                frame = .response(try OpenClawResponseEnvelope(from: decoder))
            case "event":
                frame = .event(try OpenClawEventEnvelope(from: decoder))
            default:
                throw OpenClawFrameError.unsupportedFrameType(type)
            }
        }
    }

    public init() {}

    public func decodePreAuth(_ data: Data) throws -> OpenClawInboundFrame {
        guard data.count <= OpenClawProtocol.preAuthMaximumBytes else {
            throw OpenClawFrameError.oversizedPreAuthFrame(
                actual: data.count,
                maximum: OpenClawProtocol.preAuthMaximumBytes
            )
        }
        return try decode(data)
    }

    public func decode(_ data: Data, maximumBytes: Int = Self.defaultInboundMaximumBytes) throws -> OpenClawInboundFrame {
        precondition(maximumBytes > 0)
        guard data.count <= maximumBytes else {
            throw OpenClawFrameError.oversizedInboundFrame(actual: data.count, maximum: maximumBytes)
        }
        do {
            return try JSONDecoder().decode(Envelope.self, from: data).frame
        } catch let error as OpenClawFrameError {
            throw error
        } catch {
            throw OpenClawFrameError.malformedFrame
        }
    }
}
