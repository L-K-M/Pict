#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
@testable import PictKit

/// Shared fixtures for the icon tests: synthetic images, and app bundles built in
/// a temporary directory (Zap's `UNJAILED.md`).
enum IconTestSupport {

    // MARK: Images

    /// A `PixelImage` fixture — a solid rectangle (`filled`) or a centred ellipse,
    /// fully opaque so premultiplied and straight alpha coincide. The pure raster
    /// backend's counterpart of `makeImage`, so the seam's tests run on both
    /// platforms (LP-04).
    static func makePixelImage(width: Int, height: Int, filled: Bool = true) -> PixelImage {
        // The same colour makeImage fills with: sRGB (0.2, 0.6, 0.9) ≈ (51, 153, 230).
        let r: UInt8 = 51, g: UInt8 = 153, b: UInt8 = 230
        var samples = [UInt8](repeating: 0, count: width * height * 4)
        let centreX = Double(width) / 2, centreY = Double(height) / 2
        let radiusX = Double(width) / 2, radiusY = Double(height) / 2
        for row in 0..<height {
            for column in 0..<width {
                let inside: Bool
                if filled {
                    inside = true
                } else {
                    let dx = (Double(column) + 0.5 - centreX) / radiusX
                    let dy = (Double(row) + 0.5 - centreY) / radiusY
                    inside = dx * dx + dy * dy <= 1
                }
                if inside {
                    let i = (row * width + column) * 4
                    samples[i] = r; samples[i + 1] = g; samples[i + 2] = b; samples[i + 3] = 255
                }
            }
        }
        return PixelImage(width: width, height: height, samples: samples)!
    }

    #if canImport(CoreGraphics)
    /// A solid rectangle (`filled`) or a centred ellipse, so tests can pick a
    /// full-bleed or a free-form shape.
    static func makeImage(width: Int, height: Int, filled: Bool = true) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1)
        if filled {
            context.fill(rect)
        } else {
            context.fillEllipse(in: rect)
        }
        return context.makeImage()!
    }

    /// Writes a synthetic PNG, returning the URL. Fails the build of the fixture
    /// loudly rather than silently producing an unreadable file.
    @discardableResult
    static func writePNG(width: Int, height: Int, to url: URL, filled: Bool = true) -> URL {
        let image = makeImage(width: width, height: height, filled: filled)
        guard case .success = IconImageValidator.writePNG(image, to: url) else {
            fatalError("couldn't write the test PNG at \(url.path)")
        }
        return url
    }
    #endif

    // MARK: Directories

    /// Callers must remove this in `tearDown`. `try!` rather than `try?` so a
    /// fixture that can't be set up fails as itself, instead of as a confusing
    /// "file not found" further downstream.
    static func makeTemporaryDirectory() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("PictKitTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Bundles

    /// Builds a minimal app bundle: `Contents/Info.plist` plus whatever files the
    /// test wants in `Contents/Resources`.
    ///
    /// Real `.icns` encoding isn't needed for the resolution-order tests — those
    /// only ask which files a bundle *declares*, and existence is what decides
    /// that. Tests that actually load artwork use PNGs written by `writePNG`.
    @discardableResult
    static func makeBundle(named name: String, in directory: URL,
                           info: [String: Any],
                           resources: [String: Data] = [:]) throws -> URL {
        let bundleURL = directory.appendingPathComponent("\(name).app", isDirectory: true)
        let resourcesURL = bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)

        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: bundleURL.appendingPathComponent("Contents/Info.plist"))

        for (fileName, contents) in resources {
            try contents.write(to: resourcesURL.appendingPathComponent(fileName))
        }
        return bundleURL
    }

    /// Placeholder bytes for a file whose *existence* is what a test is asserting.
    static let placeholderBytes = Data("not really an icns".utf8)
}

// The `Result` conveniences several suites use moved to `ResultConveniences.swift`
// so the pure `check()`-table tests can compile without this Core Graphics file.
