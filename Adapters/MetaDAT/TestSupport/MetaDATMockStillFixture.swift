import Foundation

/// Tiny deterministic image payload used by app-hosted MockDeviceKit tests.
/// The fixture writer owns only bytes; the host client wires the resulting URL
/// to both Meta still-image routes.
public enum MetaDATMockStillFixture {
    // 1x1 transparent PNG.
    private static let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="

    public static func write(to directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("awl-meta-still.png")
        guard let data = Data(base64Encoded: pngBase64) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url, options: .atomic)
        return url
    }
}
