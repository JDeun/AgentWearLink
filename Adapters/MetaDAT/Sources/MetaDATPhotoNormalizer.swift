import Foundation
import MWDATCamera

public struct MetaDATCapturedImage: Sendable, Equatable {
    public enum Encoding: String, Sendable { case jpeg, heic }
    public let bytes: Data
    public let encoding: Encoding
}

/// Removes SDK photo container types at the adapter boundary.
public enum MetaDATPhotoNormalizer {
    public static func normalize(_ photo: PhotoData) -> MetaDATCapturedImage {
        let encoding: MetaDATCapturedImage.Encoding = photo.format == .heic ? .heic : .jpeg
        return .init(bytes: photo.data, encoding: encoding)
    }
}
