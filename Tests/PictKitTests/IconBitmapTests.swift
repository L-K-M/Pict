#if canImport(AppKit)
import AppKit
#endif
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import XCTest
@testable import PictKit

/// The parts of icon resolution that are pure functions. The cache itself needs a
/// live `Preferences`, `NSScreen` and a background queue, so its behaviour is on
/// the manual list in Zap's `UNJAILED.md`.
final class IconBitmapTests: XCTestCase {

    // MARK: Cached size

    func testCachedPixelSizeFollowsTheBackingScale() {
        XCTAssertEqual(IconBitmap.pixelSize(forIconSize: 80, scale: 2), 160)
        XCTAssertEqual(IconBitmap.pixelSize(forIconSize: 128, scale: 2), 256)
        XCTAssertEqual(IconBitmap.pixelSize(forIconSize: 256, scale: 2), 512)
    }

    func testCachedPixelSizeHasAFloor() {
        // A tiny icon-size setting must not cache something that looks awful the
        // moment the user drags the slider back up.
        XCTAssertEqual(IconBitmap.pixelSize(forIconSize: 24, scale: 1),
                       IconImageValidator.Limits.warnBelowPixels)
    }

    func testCachedPixelSizeRoundsUp() {
        XCTAssertEqual(IconBitmap.pixelSize(forIconSize: 100.5, scale: 1.5), 151)
    }

    #if canImport(CoreGraphics)

    // MARK: Downsampling

    func testDownsampleShrinksToTheRequestedEdge() {
        let image = IconTestSupport.makeImage(width: 1024, height: 1024)
        let result = IconBitmap.downsample(image, longestEdge: 160)
        XCTAssertEqual(result.width, 160)
        XCTAssertEqual(result.height, 160)
    }

    func testDownsampleKeepsTheAspectRatio() {
        let image = IconTestSupport.makeImage(width: 800, height: 400)
        let result = IconBitmap.downsample(image, longestEdge: 200)
        XCTAssertEqual(result.width, 200)
        XCTAssertEqual(result.height, 100)
    }

    func testDownsampleNeverUpscales() {
        let image = IconTestSupport.makeImage(width: 64, height: 64)
        let result = IconBitmap.downsample(image, longestEdge: 512)
        XCTAssertEqual(result.width, 64)
    }

    // MARK: Corner masking

    /// The reason full-bleed artwork is classified separately: un-masked, a modern
    /// square icon would be the only hard-cornered thing in the row.
    func testMaskingCornersRoundsOffAFullBleedSquare() {
        let square = IconTestSupport.makeImage(width: 256, height: 256)
        XCTAssertEqual(IconShapeClassifier.classify(square), .fullBleed)

        let masked = IconBitmap.maskingCorners(
            square, radiusFraction: IconBitmap.fullBleedCornerRadiusFraction)
        XCTAssertEqual(IconShapeClassifier.classify(masked), .roundedSquare)
        XCTAssertEqual(masked.width, 256)
    }

    func testMaskingCornersWithNoRadiusLeavesTheShapeAlone() {
        let square = IconTestSupport.makeImage(width: 128, height: 128)
        let masked = IconBitmap.maskingCorners(square, radiusFraction: 0)
        XCTAssertEqual(IconShapeClassifier.classify(masked), .fullBleed)
    }

    #endif

    // MARK: Source modes

    func testSourceModeCapabilities() {
        XCTAssertFalse(IconSourceMode.system.usesBundleArtwork)
        XCTAssertFalse(IconSourceMode.system.usesCustomIcons)

        XCTAssertTrue(IconSourceMode.original.usesBundleArtwork)
        XCTAssertFalse(IconSourceMode.original.usesCustomIcons)

        XCTAssertTrue(IconSourceMode.originalPlusCustom.usesBundleArtwork)
        XCTAssertTrue(IconSourceMode.originalPlusCustom.usesCustomIcons)
    }

    /// Un-jailing only defaults on where the system actually jails icons.
    func testDefaultSourceModeMatchesTheRunningSystem() {
        XCTAssertEqual(IconSourceMode.systemDefault,
                       IconSourceMode.isSquircleJailed ? .original : .system)
    }
}
