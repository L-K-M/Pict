#if os(Linux)
import Foundation
import XCTest
@testable import PictKit

/// The Linux PNG codec (`LinuxCodec`, swift-png). The load-bearing detail is the
/// premultiplied↔straight alpha conversion at the PNG boundary — exact for
/// opaque/transparent pixels, within rounding for partial alpha.
final class PixelImageCodecTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("pictkit-codec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testOpaqueAndTransparentPixelsRoundTripExactly() throws {
        // An opaque ellipse with fully transparent corners — no partial alpha, so the
        // premultiplied samples equal the straight ones and the round-trip is exact.
        let image = IconTestSupport.makePixelImage(width: 12, height: 7, filled: false)
        let url = directory.appendingPathComponent("opaque.png")
        let codec = LinuxCodec()
        try codec.encodePNG(image, to: url)
        let back = try XCTUnwrap(codec.decode(url))
        XCTAssertEqual(back.width, image.width)
        XCTAssertEqual(back.height, image.height)
        XCTAssertEqual(back.samples, image.samples)
    }

    func testPartialAlphaRoundTripsWithinRounding() throws {
        // Premultiplied (64, 32, 16, 128): straight is (128, 64, 32, 128).
        var samples = [UInt8]()
        for _ in 0..<(4 * 4) { samples += [64, 32, 16, 128] }
        let image = try XCTUnwrap(PixelImage(width: 4, height: 4, samples: samples))
        let url = directory.appendingPathComponent("alpha.png")
        let codec = LinuxCodec()
        try codec.encodePNG(image, to: url)
        let back = try XCTUnwrap(codec.decode(url))
        XCTAssertEqual(back.width, 4)
        for i in 0..<samples.count {
            XCTAssertLessThanOrEqual(abs(Int(back.samples[i]) - Int(samples[i])), 2)
        }
    }

    func testDecodeFromDataMatchesDecodeFromPath() throws {
        let image = IconTestSupport.makePixelImage(width: 9, height: 5, filled: false)
        let url = directory.appendingPathComponent("data.png")
        let codec = LinuxCodec()
        try codec.encodePNG(image, to: url)
        let fromPath = try XCTUnwrap(codec.decode(url))
        let fromData = try XCTUnwrap(codec.decode(try Data(contentsOf: url)))
        XCTAssertEqual(fromPath.samples, fromData.samples)
    }

    func testDecodeRejectsNonPNGData() {
        XCTAssertNil(LinuxCodec().decode(Data("not a png".utf8)))
    }

    /// A crafted header declaring a gigapixel image must be rejected before swift-png
    /// decompresses it — the store is a shared directory, so a decode there faces
    /// untrusted bytes, and a 30000×30000 RGBA decode would allocate ~3.6 GB.
    func testDecodeRejectsAnOversizedHeaderWithoutDecompressing() throws {
        let image = IconTestSupport.makePixelImage(width: 8, height: 8, filled: false)
        let url = directory.appendingPathComponent("bomb.png")
        let codec = LinuxCodec()
        try codec.encodePNG(image, to: url)

        // Overwrite the IHDR width/height (big-endian UInt32 at offsets 16 and 20) with
        // 30000 (0x0000_7530) — past Limits.maximumPixelsPerAxis and maximumTotalPixels.
        var bytes = [UInt8](try Data(contentsOf: url))
        for base in [16, 20] {
            bytes[base] = 0x00; bytes[base + 1] = 0x00; bytes[base + 2] = 0x75; bytes[base + 3] = 0x30
        }
        try Data(bytes).write(to: url)

        XCTAssertNil(codec.decode(url), "an oversized IHDR must be rejected before decompressing")
        XCTAssertNil(codec.decode(try Data(contentsOf: url)))
    }
}
#endif
