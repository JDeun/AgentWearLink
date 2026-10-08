import Foundation
import MWDATCamera

public struct MetaDATCapturedImage: Sendable, Equatable {
    public enum Encoding: String, Sendable { case jpeg, heic }
    public let bytes: Data
    public let encoding: Encoding
}

public enum MetaDATPhotoNormalizationError: Error, Sendable, Equatable {
    case payloadTooLarge(actual: Int, maximum: Int)
    case unexpectedJPEGEncoding
}

/// Removes SDK photo container types at the adapter boundary.
///
/// The vendor SDK has already materialized `PhotoData.data` before this
/// boundary. AWL therefore cannot prevent that vendor allocation, but it can
/// reject an oversized still before retaining it as `MetaDATCapturedImage` or
/// forwarding it toward vision processing.
public enum MetaDATPhotoNormalizer {
    /// Conservative ceiling for one captured still image.
    ///
    /// Callers may lower this to match a downstream agent/transport budget, but
    /// should not raise it implicitly from untrusted remote input.
    public static let defaultMaximumBytes = 16 * 1024 * 1024

    public static func normalize(
        _ photo: PhotoData,
        maximumBytes: Int = defaultMaximumBytes
    ) throws -> MetaDATCapturedImage {
        let data = photo.data
        try validatePayload(data, maximumBytes: maximumBytes)

        let encoding: MetaDATCapturedImage.Encoding =
            photo.format == .heic ? .heic : .jpeg
        return .init(bytes: data, encoding: encoding)
    }

    /// Stream.capturePhoto(format: .jpeg) is the only supported default
    /// bridge output. Reject obviously mislabeled PNG/HEIC/corrupt payloads
    /// before forwarding bytes as image/jpeg to OpenClaw. This checks the
    /// signature, not full image decodability (which is the consumer's job).
    static func validateStreamJPEG(
        _ data: Data,
        maximumBytes: Int
    ) throws {
        try validatePayload(data, maximumBytes: maximumBytes)
        guard data.count >= 3,
              data[data.startIndex] == 0xFF,
              data[data.startIndex + 1] == 0xD8,
              data[data.startIndex + 2] == 0xFF else {
            throw MetaDATPhotoNormalizationError.unexpectedJPEGEncoding
        }
    }

    static func validatePayload(
        _ data: Data,
        maximumBytes: Int
    ) throws {
        precondition(maximumBytes > 0)

        guard data.count <= maximumBytes else {
            throw MetaDATPhotoNormalizationError.payloadTooLarge(
                actual: data.count,
                maximum: maximumBytes
            )
        }
    }
}
