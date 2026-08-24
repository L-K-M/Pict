#if os(Linux)
import Foundation
import PNG

/// The Linux `IconCodec`: PNG in and out via the pure-Swift `swift-png`, with the
/// one conversion that matters at this boundary — `PixelImage` is **premultiplied**
/// RGBA, PNG is **straight** (non-premultiplied) alpha. Decoding premultiplies;
/// encoding un-premultiplies. The round-trip is exact for opaque pixels and within
/// rounding for partial alpha (`PixelImageCodecTests`).
struct LinuxCodec: IconCodec {

    func decode(_ url: URL) -> PixelImage? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: Self.headerLength),
              Self.dimensionsWithinLimits(header) else { return nil }
        guard let image = try? PNG.Image.decompress(path: url.path) else { return nil }
        return Self.pixelImage(from: image)
    }

    func decode(_ data: Data) -> PixelImage? {
        guard Self.dimensionsWithinLimits(data) else { return nil }
        var source = ArraySource(bytes: [UInt8](data))
        guard let image = try? PNG.Image.decompress(stream: &source) else { return nil }
        return Self.pixelImage(from: image)
    }

    // MARK: Header guard

    /// The bytes needed to read the PNG signature (8) plus the IHDR chunk length + type
    /// + width + height (16).
    private static let headerLength = 24

    /// Rejects a PNG whose IHDR declares dimensions past `IconImageValidator.Limits`
    /// **before** swift-png decompresses it, so a crafted header can't make the codec
    /// allocate a gigapixel decode buffer — the memory-exhaustion vector a shared,
    /// world-writable store dir would otherwise open on Linux (the LP-03/04
    /// decompression-bomb follow-up). A malformed or too-short header is passed through
    /// as "within limits" and left to swift-png to reject, so this only ever *adds*
    /// rejections for oversized images; the minimum-size floor stays a store policy
    /// (`IconStore.image(for:)`), matching the macOS decode.
    private static func dimensionsWithinLimits(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        guard bytes.count >= headerLength else { return true }
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard Array(bytes[0..<8]) == signature,
              Array(bytes[12..<16]) == Array("IHDR".utf8) else { return true }
        // IHDR width and height are big-endian UInt32 at byte offsets 16 and 20.
        let width = Int(bytes[16]) << 24 | Int(bytes[17]) << 16 | Int(bytes[18]) << 8 | Int(bytes[19])
        let height = Int(bytes[20]) << 24 | Int(bytes[21]) << 16 | Int(bytes[22]) << 8 | Int(bytes[23])
        guard width > 0, height > 0 else { return false }
        return width <= IconImageValidator.Limits.maximumPixelsPerAxis
            && height <= IconImageValidator.Limits.maximumPixelsPerAxis
            && width * height <= IconImageValidator.Limits.maximumTotalPixels
    }

    func encodePNG(_ image: PixelImage, to url: URL) throws {
        let pixels = Self.straightRGBA(from: image)
        let png = PNG.Image(packing: pixels, size: (image.width, image.height),
                            layout: .init(format: .rgba8(palette: [], fill: nil)))
        // Compression level 4, not swift-png's default (9). Measured on this
        // codec/version, the default is the worst of both worlds for icon artwork:
        // levels 0–6 encode an icon-sized image about equally and small, while 8–9 are
        // markedly slower *and* produce larger files. Icons are flat-colour artwork
        // that compresses well at any level, so 4 is fast and gives the smallest output.
        try png.compress(path: url.path, level: 4)
    }

    // MARK: Conversion

    /// swift-png RGBA (straight alpha) -> premultiplied `PixelImage`.
    private static func pixelImage(from image: PNG.Image) -> PixelImage? {
        let (width, height) = image.size
        // Cap accepted dimensions to the same budget the Core Graphics path enforces
        // (IconImageValidator.Limits), so a crafted header can't make PictKit build a
        // gigapixel PixelImage. swift-png still allocates the decode itself; when
        // ingestion lands on Linux, a header check before decompress would move this
        // guard earlier (LP-03 review follow-up).
        guard width > 0, height > 0,
              width <= IconImageValidator.Limits.maximumPixelsPerAxis,
              height <= IconImageValidator.Limits.maximumPixelsPerAxis,
              width * height <= IconImageValidator.Limits.maximumTotalPixels else { return nil }
        let rgba = image.unpack(as: PNG.RGBA<UInt8>.self)
        guard rgba.count == width * height else { return nil }
        var samples = [UInt8](repeating: 0, count: width * height * 4)
        for index in 0..<rgba.count {
            let pixel = rgba[index]
            let a = Int(pixel.a)
            let o = index * 4
            samples[o] = premultiply(Int(pixel.r), a)
            samples[o + 1] = premultiply(Int(pixel.g), a)
            samples[o + 2] = premultiply(Int(pixel.b), a)
            samples[o + 3] = pixel.a
        }
        return PixelImage(width: width, height: height, samples: samples)
    }

    /// Premultiplied `PixelImage` -> swift-png RGBA (straight alpha).
    private static func straightRGBA(from image: PixelImage) -> [PNG.RGBA<UInt8>] {
        var pixels = [PNG.RGBA<UInt8>]()
        pixels.reserveCapacity(image.width * image.height)
        image.samples.withUnsafeBufferPointer { src in
            for index in 0..<(image.width * image.height) {
                let o = index * 4
                let a = Int(src[o + 3])
                pixels.append(PNG.RGBA(unpremultiply(Int(src[o]), a),
                                       unpremultiply(Int(src[o + 1]), a),
                                       unpremultiply(Int(src[o + 2]), a),
                                       src[o + 3]))
            }
        }
        return pixels
    }

    /// `straight * alpha / 255`, rounded.
    private static func premultiply(_ value: Int, _ alpha: Int) -> UInt8 {
        UInt8((value * alpha + 127) / 255)
    }

    /// `premultiplied * 255 / alpha`, rounded and clamped; 0 for a transparent pixel.
    private static func unpremultiply(_ value: Int, _ alpha: Int) -> UInt8 {
        guard alpha > 0 else { return 0 }
        return UInt8(Swift.min(255, (value * 255 + alpha / 2) / alpha))
    }

    /// An in-memory `PNG.BytestreamSource` over a byte array, for `decode(_ data:)`.
    private struct ArraySource: PNG.BytestreamSource {
        let bytes: [UInt8]
        var offset: Int = 0
        mutating func read(count: Int) -> [UInt8]? {
            guard offset + count <= bytes.count else { return nil }
            defer { offset += count }
            return [UInt8](bytes[offset ..< offset + count])
        }
    }
}
#endif
