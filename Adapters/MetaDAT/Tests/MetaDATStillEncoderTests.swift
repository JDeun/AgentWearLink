import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import AgentWearLinkMetaDATIntegration

final class MetaDATStillEncoderTests: XCTestCase {
    func testCapsLongSideAndKeepsAspect() throws {
        let source = try Self.jpeg(width: 1080, height: 1440)
        let output = try MetaDATStillEncoder.jpeg(from: source)
        XCTAssertEqual(output.height, 1280)
        XCTAssertEqual(output.width, 960)
        XCTAssertEqual(Array(output.jpeg.prefix(3)), [0xFF, 0xD8, 0xFF])
    }

    func testNeverUpscalesSmallStill() throws {
        let output = try MetaDATStillEncoder.jpeg(from: Self.jpeg(width: 640, height: 480))
        XCTAssertEqual(output.width, 640)
        XCTAssertEqual(output.height, 480)
    }

    func testDecodesPNGToo() throws {
        let output = try MetaDATStillEncoder.jpeg(from: Self.encode(width: 300, height: 200, type: .png))
        XCTAssertEqual(output.width, 300)
        XCTAssertEqual(Array(output.jpeg.prefix(2)), [0xFF, 0xD8])
    }

    func testRejectsGarbage() {
        XCTAssertThrowsError(try MetaDATStillEncoder.jpeg(from: Data([1, 2, 3, 4]))) { error in
            XCTAssertEqual(error as? MetaDATStillEncoderError, .undecodable)
        }
    }

    func testDropsSourceMetadata() throws {
        let output = try MetaDATStillEncoder.jpeg(from: Self.jpeg(width: 400, height: 300, gps: true))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(output.jpeg as CFData, nil))
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        XCTAssertNil(properties?[kCGImagePropertyGPSDictionary])
    }

    func testTimingsLogLineIsNumbersOnly() {
        var timings = MetaDATSnapshotTimings(mode: .compatibleStreamStill)
        timings.attachMilliseconds = 12
        timings.readyMilliseconds = 1800
        timings.photoMilliseconds = 900
        timings.stopMilliseconds = 4
        timings.encodeMilliseconds = 40
        timings.totalMilliseconds = 2756
        timings.width = 960
        timings.height = 1280
        timings.rawBytes = 400 * 1024
        timings.jpegBytes = 180 * 1024
        XCTAssertEqual(
            timings.logLine,
            "photo timings [stream]: attach 12 ms, first frame 1800 ms, photo 900 ms, stop 4 ms, encode 40 ms, total 2756 ms, 960x1280, 400→180 KB"
        )
        var standalone = MetaDATSnapshotTimings(mode: .experimentalStandalonePhoto)
        standalone.attachMilliseconds = 10
        XCTAssertEqual(
            standalone.logLine,
            "photo timings [standalone]: attach 10 ms, started —, photo —, encode —, total —"
        )
    }

    func testMillisecondsConversion() {
        XCTAssertEqual(MetaDATCameraSnapshotController.milliseconds(.milliseconds(2345)), 2345)
        XCTAssertEqual(MetaDATCameraSnapshotController.milliseconds(.seconds(3)), 3000)
    }

    static func jpeg(width: Int, height: Int, gps: Bool = false) throws -> Data {
        try encode(width: width, height: height, type: .jpeg, gps: gps)
    }

    static func encode(width: Int, height: Int, type: UTType, gps: Bool = false) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        var properties: [CFString: Any] = [:]
        if gps {
            properties[kCGImagePropertyGPSDictionary] = [kCGImagePropertyGPSLatitude: 37.5, kCGImagePropertyGPSLongitude: 127.0]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
