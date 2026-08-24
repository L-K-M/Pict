import Foundation

/// A source of a target's own artwork as a `PixelImage`, for the read-side status
/// (`IconArtworkStatus`) that only needs to classify a shape, not render it.
///
/// Behind a protocol so the platform's provider can vary: macOS reads the app bundle
/// (`BundleArtwork`); Linux has no bundle equivalent, and a real icon-theme lookup
/// arrives in LP-24 — until then it returns nothing. `Sendable` because the batch
/// `IconArtworkStatus.load` hands a provider to a background queue.
public protocol ArtworkProviding: Sendable {
    func artwork(for target: IconTarget) -> PixelImage?
}

#if canImport(AppKit)
/// The macOS provider: an app's own icon out of its bundle, sampled into a
/// `PixelImage` for classification. `IconShapeClassifier.classify` agrees across the
/// CGImage↔PixelImage seam (`PixelImageTests`), so the shape this yields is the one
/// the Core Graphics path would report.
public struct BundleArtworkProvider: ArtworkProviding {
    public init() {}
    public func artwork(for target: IconTarget) -> PixelImage? {
        guard case .application(_, let bundleIdentifier) = target, let bundleIdentifier,
              let image = BundleArtwork.image(forBundleID: bundleIdentifier) else { return nil }
        return PixelImage(cgImage: image)
    }
}
#else
/// The Linux placeholder: there is no app-bundle artwork to read, and icon-theme
/// lookup lands in LP-24. Returning `nil` makes the status read as "no original
/// artwork found", which is the honest answer until then.
public struct BundleArtworkProvider: ArtworkProviding {
    public init() {}
    public func artwork(for target: IconTarget) -> PixelImage? { nil }
}
#endif
