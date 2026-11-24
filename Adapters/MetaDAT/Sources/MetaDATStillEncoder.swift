import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum MetaDATStillEncoderError: Error, Sendable, Equatable {
    case undecodable
    case encodeFailed
}

/// Re-encodes one captured still (JPEG or HEIC) as a JPEG for an agent turn:
/// long side capped (never upscaled), fixed quality, orientation applied and
/// all source metadata dropped (the new image carries no EXIF). Runs on the
/// caller's task; a ~1440 px still takes tens of milliseconds on an iPhone.
public enum MetaDATStillEncoder {
    public static let defaultMaximumLongSide = 1280
    public static let defaultQuality = 0.7

    public struct Output: Sendable, Equatable {
        public let jpeg: Data
        public let width: Int
        public let height: Int
    }

    public static func jpeg(
        from data: Data,
        maximumLongSide: Int = defaultMaximumLongSide,
        quality: Double = defaultQuality
    ) throws -> Output {
        precondition(maximumLongSide > 0)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw MetaDATStillEncoderError.undecodable
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumLongSide,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw MetaDATStillEncoderError.undecodable
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil
        ) else {
            throw MetaDATStillEncoderError.encodeFailed
        }
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: min(1, max(0, quality)),
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length > 0 else {
            throw MetaDATStillEncoderError.encodeFailed
        }
        return Output(jpeg: output as Data, width: image.width, height: image.height)
    }
}
