#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import XCTest
@testable import PictKit

final class PixelImageTests: XCTestCase {

    // MARK: Orientation (pure — runs on both platforms)

    /// `PixelImage` row 0 is the top, and `AlphaMask(pixelImage:)` reads it that way
    /// — the same convention `AlphaMask(image:)` uses, so the two never disagree on a
    /// vertically asymmetric icon. (The bug this pins down: an inverted `PixelImage`
    /// would put the opaque top at the bottom row.)
    func testPixelImageRowZeroIsTheTopRow() throws {
        let side = 16
        var samples = [UInt8](repeating: 0, count: side * side * 4)
        for row in 0..<side {
            let alpha: UInt8 = row < side / 2 ? 255 : 0   // opaque top half, clear bottom
            for column in 0..<side {
                let index = (row * side + column) * 4
                samples[index + 3] = alpha   // premultiplied black: only alpha set
            }
        }
        let image = try XCTUnwrap(PixelImage(width: side, height: side, samples: samples))

        let mask = try XCTUnwrap(AlphaMask(pixelImage: image, longestEdge: side))
        XCTAssertTrue(mask.isInk(row: 0, column: side / 2, threshold: 128),
                      "row 0 is the opaque top")
        XCTAssertFalse(mask.isInk(row: side - 1, column: side / 2, threshold: 128),
                       "the last row is the transparent bottom")
    }

    func testPixelImageRejectsAMismatchedSampleCount() {
        XCTAssertNil(PixelImage(width: 4, height: 4, samples: [UInt8](repeating: 0, count: 10)))
        XCTAssertNil(PixelImage(width: 0, height: 4, samples: []))
    }

    /// Extreme dimensions (as a crafted PNG header could carry) must return nil,
    /// not trap on the `width * height * 4` overflow. 2^31 × 2^31 × 4 = 2^64,
    /// which overflows Int; the guard catches it before the multiply.
    func testPixelImageRejectsOverflowingDimensions() {
        XCTAssertNil(PixelImage(width: 1 << 31, height: 1 << 31, samples: []))
    }

    #if canImport(CoreGraphics)

    // MARK: The Core Graphics bridge (macOS)

    /// Opaque top half, transparent bottom — asymmetric on purpose, so a mirrored
    /// conversion is caught.
    private static func topHalfOpaqueImage(side: Int = 16) -> CGImage? {
        guard let context = IconBitmap.makeContext(width: side, height: side) else { return nil }
        let edge = CGFloat(side)
        context.clear(CGRect(x: 0, y: 0, width: edge, height: edge))
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        // A bitmap context is bottom-up, so the image's TOP half is the high-y half.
        context.fill(CGRect(x: 0, y: edge / 2, width: edge, height: edge - edge / 2))
        return context.makeImage()
    }

    func testInitFromCGImageKeepsRowZeroAtTheTop() throws {
        let side = 16
        let image = try XCTUnwrap(Self.topHalfOpaqueImage(side: side))
        let pixel = try XCTUnwrap(PixelImage(cgImage: image))

        XCTAssertEqual(pixel.width, side)
        XCTAssertEqual(pixel.height, side)
        // Row 0 (top) is opaque; the last row (bottom) is clear.
        XCTAssertEqual(pixel.samples[3], 255, "row 0 alpha")
        XCTAssertEqual(pixel.samples[(side - 1) * side * 4 + 3], 0, "last row alpha")
    }

    func testCGImageRoundTripPreservesSamples() throws {
        let image = try XCTUnwrap(Self.topHalfOpaqueImage())
        let pixel = try XCTUnwrap(PixelImage(cgImage: image))
        let rebuilt = try XCTUnwrap(pixel.makeCGImage())
        let resampled = try XCTUnwrap(PixelImage(cgImage: rebuilt))

        XCTAssertEqual(resampled.width, pixel.width)
        XCTAssertEqual(resampled.height, pixel.height)
        XCTAssertEqual(resampled.samples, pixel.samples,
                       "init(cgImage:) and makeCGImage() are inverses")
    }

    /// The seam's promise: the CG path and the PixelImage path classify the same
    /// artwork the same way. Uses the classifier (wide margins) rather than exact
    /// mask equality, since the two downsamplers differ in interpolation.
    func testClassificationAgreesAcrossTheSeam() throws {
        let square = IconTestSupport.makeImage(width: 128, height: 128, filled: true)
        let ellipse = IconTestSupport.makeImage(width: 128, height: 128, filled: false)
        // A vertically asymmetric shape too, for good measure — the flip itself is
        // pinned by testInitFromCGImageKeepsRowZeroAtTheTop (classification is
        // orientation-invariant), but this checks another shape class across the seam.
        let asymmetric = try XCTUnwrap(Self.topHalfOpaqueImage(side: 128))

        for image in [square, ellipse, asymmetric] {
            let pixel = try XCTUnwrap(PixelImage(cgImage: image))
            XCTAssertEqual(IconShapeClassifier.classify(image),
                           IconShapeClassifier.classify(pixel),
                           "CG and PixelImage classification must agree")
        }
    }

    /// Both sampling paths must agree on grid dimensions for *any* aspect ratio —
    /// the square fixtures above exercise the rounding only trivially. 61/130*48
    /// rounds to 23, and a one-cell drift between the CG and pure paths would skew
    /// AlphaProfile only for non-square artwork.
    func testGridDimensionsAgreeAcrossTheSeam() throws {
        let image = IconTestSupport.makeImage(width: 130, height: 61, filled: true)
        let pixel = try XCTUnwrap(PixelImage(cgImage: image))
        let viaCG = try XCTUnwrap(AlphaMask(image: image, longestEdge: 48))
        let viaPixel = try XCTUnwrap(AlphaMask(pixelImage: pixel, longestEdge: 48))
        XCTAssertEqual(viaCG.width, viaPixel.width)
        XCTAssertEqual(viaCG.height, viaPixel.height)
    }
    #endif
}
