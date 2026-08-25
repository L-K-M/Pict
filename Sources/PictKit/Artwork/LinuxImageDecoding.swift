#if os(Linux)
import Foundation

/// The Linux decode primitive a store-ingesting front end needs, exposed for the
/// `pict` CLI (LP-14).
///
/// `LinuxCodec` is internal, and the `pict` CLI lives in its own target — but it must
/// turn a user-supplied PNG into a `PixelImage` before handing it to
/// `IconStore.setIcon`. Reusing `LinuxCodec` here (rather than the CLI decoding PNG
/// itself) keeps exactly one codec, so the **premultiplied**-alpha convention
/// `setIcon` → `encodePNG` round-trips through is guaranteed identical; a second
/// decoder that produced straight-alpha pixels would be silently corrupted by the
/// encoder's un-premultiply step.
///
/// PNG only, and deliberately *not* a method on `IconStore`: turning a file into an
/// image is ingestion, which lives in the consumer, and a URL-decoding convenience on
/// the store is the "silently refuses every SVG" trap `IconStore.setIcon` documents.
/// The macOS CLI path uses `IconImageValidator.decode(contentsOf:)` instead (ImageIO),
/// so this Linux-only helper is the whole cross-platform gap it fills.
public enum LinuxImageDecoding {

    /// Decodes the PNG at `url` into a `PixelImage`, bounded to `IconImageValidator.Limits`
    /// exactly as `IconStore` bounds it on read. Returns `nil` if the file can't be read
    /// as an in-range PNG. The caller still applies the accept gate
    /// (`IconImageValidator.check`, for the minimum-size floor and aspect ratio) before
    /// storing — matching what `IconImageValidator.decode` enforces on macOS.
    public static func decodePNG(contentsOf url: URL) -> PixelImage? {
        LinuxCodec().decode(url)
    }
}
#endif
