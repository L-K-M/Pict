import Foundation
import XCTest
@testable import PictKit

/// The raster backend behind the LP-03 seam: `PixelImage` downsample / corner-mask /
/// normalize, exercised on both platforms (on Linux it's the shipping path; on
/// macOS it runs alongside the Core Graphics path these mirror). Fixtures come from
/// `IconTestSupport.makePixelImage`, so no Core Graphics is involved.
final class PixelImageRenderTests: XCTestCase {

    // MARK: Downsampling

    func testDownsampleShrinksToTheRequestedEdge() {
        let result = IconBitmap.downsample(IconTestSupport.makePixelImage(width: 1024, height: 1024),
                                           longestEdge: 160)
        XCTAssertEqual(result.width, 160)
        XCTAssertEqual(result.height, 160)
    }

    func testDownsampleKeepsTheAspectRatio() {
        let result = IconBitmap.downsample(IconTestSupport.makePixelImage(width: 800, height: 400),
                                           longestEdge: 200)
        XCTAssertEqual(result.width, 200)
        XCTAssertEqual(result.height, 100)
    }

    func testDownsampleNeverUpscales() {
        let result = IconBitmap.downsample(IconTestSupport.makePixelImage(width: 64, height: 64),
                                           longestEdge: 512)
        XCTAssertEqual(result.width, 64)
    }

    // MARK: Corner masking

    func testMaskingCornersRoundsOffAFullBleedSquare() {
        let square = IconTestSupport.makePixelImage(width: 256, height: 256)
        XCTAssertEqual(IconShapeClassifier.classify(square), .fullBleed)

        let masked = IconBitmap.maskingCorners(square, radiusFraction: IconBitmap.fullBleedCornerRadiusFraction)
        XCTAssertEqual(IconShapeClassifier.classify(masked), .roundedSquare)
        XCTAssertEqual(masked.width, 256)
    }

    func testMaskingCornersWithNoRadiusLeavesTheShapeAlone() {
        let square = IconTestSupport.makePixelImage(width: 128, height: 128)
        let masked = IconBitmap.maskingCorners(square, radiusFraction: 0)
        XCTAssertEqual(IconShapeClassifier.classify(masked), .fullBleed)
    }

    // MARK: Normalize

    func testNormalizeRendersIntoTheBleedCanvas() {
        let image = IconTestSupport.makePixelImage(width: 512, height: 512, filled: false)
        let result = IconNormalizer.normalize(image, targetExtent: 200, bleed: 0.1, trim: true, shadow: false)
        // 200 * (1 + 0.2) = 240 on each side.
        XCTAssertEqual(result.width, 240)
        XCTAssertEqual(result.height, 240)
    }

    func testNormalizeWithoutBleedRendersAtTheNominalExtent() {
        let image = IconTestSupport.makePixelImage(width: 256, height: 256)
        let result = IconNormalizer.normalize(image, targetExtent: 128, bleed: 0, trim: true, shadow: false)
        XCTAssertEqual(result.width, 128)
    }

    /// Trimming has to recover artwork from its transparent margin, or a padded icon
    /// stays small in its cell.
    func testTrimmingRecoversArtworkFromATransparentMargin() throws {
        // An ellipse occupying the middle half of an otherwise empty canvas.
        let side = 400
        var samples = [UInt8](repeating: 0, count: side * side * 4)
        for row in 100..<300 {
            for column in 100..<300 {
                let dx = (Double(column) + 0.5 - 200) / 100
                let dy = (Double(row) + 0.5 - 200) / 100
                if dx * dx + dy * dy <= 1 {
                    let i = (row * side + column) * 4
                    samples[i] = 51; samples[i + 1] = 153; samples[i + 2] = 230; samples[i + 3] = 255
                }
            }
        }
        let padded = try XCTUnwrap(PixelImage(width: side, height: side, samples: samples))

        let trimmed = IconNormalizer.normalize(padded, targetExtent: 200, bleed: 0.15, trim: true, shadow: false)
        let untrimmed = IconNormalizer.normalize(padded, targetExtent: 200, bleed: 0.15, trim: false, shadow: false)

        XCTAssertEqual(trimmed.width, untrimmed.width)
        XCTAssertGreaterThan(try inkFraction(of: trimmed), try inkFraction(of: untrimmed) * 1.5,
                             "trimming should put substantially more ink on the canvas")
    }

    // MARK: Shadow

    func testShadowAddsCoverageOutsideTheArtwork() throws {
        let image = IconTestSupport.makePixelImage(width: 256, height: 256, filled: false)
        let plain = IconNormalizer.normalize(image, targetExtent: 200, bleed: 0.15, trim: true, shadow: false)
        let shadowed = IconNormalizer.normalize(image, targetExtent: 200, bleed: 0.15, trim: true, shadow: true)
        XCTAssertGreaterThan(try inkFraction(of: shadowed, threshold: 8),
                             try inkFraction(of: plain, threshold: 8))
    }

    /// The shadow falls **below** the artwork — the whole difference between a shadow
    /// and an outline. `PixelImage` row 0 is the top, so `maxRow` is the bottom edge.
    /// A solid square, deliberately: scaled down inside the bleed canvas, leaving room
    /// for the shadow to land rather than be clipped by the edge.
    func testTheShadowFallsBelowTheArtwork() throws {
        let image = IconTestSupport.makePixelImage(width: 256, height: 256)
        let shadowed = IconNormalizer.normalize(image, targetExtent: 200, bleed: 0.15, trim: true, shadow: true)

        let mask = try XCTUnwrap(AlphaMask(pixelImage: shadowed, longestEdge: 128))
        let ink = try XCTUnwrap(mask.inkBounds(threshold: 200), "the artwork itself")
        let withShadow = try XCTUnwrap(mask.inkBounds(threshold: 8), "artwork plus shadow")

        let reachBelow = withShadow.maxRow - ink.maxRow
        let reachAbove = ink.minRow - withShadow.minRow
        XCTAssertGreaterThan(reachBelow, 0, "the shadow has to show past the ink at all")
        XCTAssertGreaterThan(reachBelow, reachAbove,
                             "a shadow offset downward must reach further below than above")
    }

    /// Faint enough to be lift rather than a second shape: strictly outside the
    /// artwork, every shadow sample stays below what the app calls ink.
    func testTheShadowNeverReadsAsInk() throws {
        let image = IconTestSupport.makePixelImage(width: 256, height: 256)
        let plain = IconNormalizer.normalize(image, targetExtent: 200, bleed: 0.15, trim: true, shadow: false)
        let shadowed = IconNormalizer.normalize(image, targetExtent: 200, bleed: 0.15, trim: true, shadow: true)

        let artworkMask = try XCTUnwrap(AlphaMask(pixelImage: plain, longestEdge: 128))
        let artwork = try XCTUnwrap(artworkMask.inkBounds(threshold: 1))
        let mask = try XCTUnwrap(AlphaMask(pixelImage: shadowed, longestEdge: 128))

        var strongestOutside: UInt8 = 0
        for row in 0..<mask.height {
            for column in 0..<mask.width {
                let insideArtwork = row >= artwork.minRow && row <= artwork.maxRow
                    && column >= artwork.minColumn && column <= artwork.maxColumn
                guard !insideArtwork else { continue }
                strongestOutside = max(strongestOutside, mask.samples[row * mask.width + column])
            }
        }

        XCTAssertGreaterThan(strongestOutside, 0, "the shadow has to be visible at all")
        XCTAssertLessThan(strongestOutside, IconShapeClassifier.inkThreshold,
                          "the shadow must stay below what the rest of the app calls ink")
    }

    private func inkFraction(of image: PixelImage, threshold: UInt8 = 128) throws -> Double {
        let mask = try XCTUnwrap(AlphaMask(pixelImage: image, longestEdge: 128))
        return Double(mask.inkCount(threshold: threshold)) / Double(mask.width * mask.height)
    }
}
