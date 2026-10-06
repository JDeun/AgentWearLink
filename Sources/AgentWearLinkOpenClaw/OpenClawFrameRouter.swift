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

/// Validates the pre-auth ceiling and decodes only the outer frame family.
/// Runtime-specific payload decoding happens after routing.
public struct OpenClawFrameRouter: Sendable {
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
        guard
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = object["type"] as? String
        else {
            throw OpenClawFrameError.malformedFrame
        }

        switch type {
        case "res":
            return .response(
                try JSONDecoder().decode(OpenClawResponseEnvelope.self, from: data)
            )
        case "event":
            return .event(
                try JSONDecoder().decode(OpenClawEventEnvelope.self, from: data)
            )
        default:
            throw OpenClawFrameError.unsupportedFrameType(type)
        }
    }
}
