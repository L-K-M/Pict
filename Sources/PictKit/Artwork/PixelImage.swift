#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

/// A platform-neutral raster: RGBA8, premultiplied, row-major, row 0 = top.
///
/// The seam that lets the artwork pipeline compile on Linux. On macOS every entry
/// point still takes a `CGImage`; the pure-math steps (classify, layout, validate)
/// were already CG-free, and this type carries the pixels for the steps that need
/// them without pulling in Core Graphics. The Linux raster backend (a PNG codec and
/// pure pixel ops) lands in LP-04 behind the `IconCodec` protocol below.
///
/// **Premultiplied**, to match Core Graphics' `premultipliedLast` bitmaps and the
/// alpha math the classifier/normaliser already assume. PNG is *straight* alpha, so
/// a codec converts at that boundary (LP-04).
public struct PixelImage: Equatable, Sendable {

    public let width: Int
    public let height: Int

    /// `width * height * 4` bytes, RGBA order, premultiplied, row-major.
    public let samples: [UInt8]

    /// Builds an image from raw samples, or `nil` when the count doesn't match the
    /// dimensions. The overflow check runs before `width * height * 4` is evaluated:
    /// this initializer is the seam LP-04's PNG codec feeds with dimensions parsed
    /// from untrusted file headers, and Swift traps (not wraps) on `Int` overflow —
    /// so extreme dimensions must return `nil`, never crash.
    public init?(width: Int, height: Int, samples: [UInt8]) {
        guard width > 0, height > 0,
              width <= (Int.max / 4) / height,
              samples.count == width * height * 4 else { return nil }
        self.width = width
        self.height = height
        self.samples = samples
    }
}

/// Turns bytes on disk (or in memory) into a `PixelImage`, and back out as PNG.
///
/// One conformer per platform: Core Graphics + ImageIO on macOS (through
/// `IconImageValidator`), a pure-Swift PNG codec on Linux (LP-04). Kept deliberately
/// small — decode, decode-from-data, encode — so a platform only has to implement
/// the three operations the store and resolver actually need.
public protocol IconCodec {
    func decode(_ url: URL) -> PixelImage?
    func decode(_ data: Data) -> PixelImage?
    func encodePNG(_ image: PixelImage, to url: URL) throws
}

#if canImport(CoreGraphics)
public extension PixelImage {

    /// Samples a `CGImage` into premultiplied RGBA8, row 0 = top — the inverse of
    /// `makeCGImage()`. Uses the same `premultipliedLast` sRGB context the alpha
    /// classifier and normaliser draw into (`AlphaMask.init(image:)`,
    /// `IconBitmap.makeContext`), so the pixel format is identical across the seam.
    init?(cgImage image: CGImage) {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        var samples = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let drawn: Bool = samples.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress,
                  let context = CGContext(data: base, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            // A bitmap context's backing memory is row 0 = top, and drawing with
            // the identity CTM lands the image's first scanline in memory row 0 —
            // the same convention `AlphaMask.init(image:)` samples through and the
            // exact inverse of `makeCGImage()`. (No flip: a flip here would mirror
            // the result and break parity with the CG path.)
            context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            return true
        }
        guard drawn else { return nil }
        self.init(width: width, height: height, samples: samples)
    }

    /// Rebuilds a `CGImage` from the premultiplied RGBA8 samples (row 0 = top).
    func makeCGImage() -> CGImage? {
        guard let provider = CGDataProvider(data: Data(samples) as CFData) else { return nil }
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return CGImage(width: width, height: height,
                       bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }
}
#endif
