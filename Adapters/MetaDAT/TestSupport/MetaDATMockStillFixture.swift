import Foundation
import UIKit

/// Deterministic 1x1 image fixture used by the app-hosted MockDeviceKit tests.
/// The production stream shutter requests JPEG. Do not install PNG bytes into
/// a fixture that the adapter later hands off as image/jpeg.
public enum MetaDATMockStillFixture {
    private static let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="

    public static func write(to directory: URL) throws -> URL {
        guard let png = Data(base64Encoded: pngBase64),
              let image = UIImage(data: png),
              let jpeg = image.jpegData(compressionQuality: 0.9) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let url = directory.appendingPathComponent("awl-meta-still.jpg")
        try jpeg.write(to: url, options: .atomic)
        return url
    }
}
