import Foundation

public enum OpenClawInboundFrame: Sendable, Equatable {
    case response(OpenClawResponseEnvelope)
    case event(OpenClawEventEnvelope)
}

public enum OpenClawFrameError: Error, Sendable, Equatable {
    case oversizedPreAuthFrame(actual: Int, maximum: Int)
    case malformedFrame
    case unsupportedFrameType(String)
}

/// Validates the pre-auth ceiling and decodes each inbound JSON frame once.
public struct OpenClawFrameRouter: Sendable {
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

    public func decode(_ data: Data) throws -> OpenClawInboundFrame {
        do {
            return try JSONDecoder().decode(Envelope.self, from: data).frame
        } catch let error as OpenClawFrameError {
            throw error
        } catch {
            throw OpenClawFrameError.malformedFrame
        }
    }
}
