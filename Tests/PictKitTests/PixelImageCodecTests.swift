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
}
#endif
