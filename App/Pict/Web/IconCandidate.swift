import CoreGraphics
import Foundation
import PictKit

/// An image fetched out of the web browser and decoded, but **not yet applied**.
///
/// The step this type exists for: the first version went straight from right-click
/// to stored icon, then raised an alert afterwards if the picture turned out to be
/// too small. By then the browser had closed, so the one thing the warning should
/// prompt — go back and pick a better one — meant reopening the browser, finding
/// the page again and re-running the search. The warning arrived exactly when it
/// had become expensive to act on.
///
/// So the decision moves in front of the commit. Everything needed to judge a
/// picture is gathered here, shown while the browser is still open behind it, and
/// only then written.
struct IconCandidate: Identifiable {

    let id = UUID()
    /// The decoded, validated image — the same bytes that would be stored, so what
    /// the preview shows is what the icon becomes.
    let image: CGImage
    /// Where it came from, for the credit and for "open this page again".
    let picked: PickedWebImage
    /// What was actually fetched, which is the original rather than the thumbnail
    /// when the resolver found one.
    let fetchedURL: URL
    /// `false` when this is the thumbnail because no original could be found.
    let isOriginal: Bool
    /// The resolver's own account of why this URL may disappoint, when it has one.
    /// Carried rather than re-derived: it knows things this type cannot, such as
    /// whether the address was a known thumbnail host.
    let resolverNote: String?
    /// How the artwork sits in its canvas, from the same classifier the resolver
    /// uses when deciding whether to substitute a bundle's own icon.
    ///
    /// The classification rather than the raw `fillRatio` behind it: the ratio is a
    /// number no user needs, and every question this type answers — is there
    /// transparency, is there artwork at all — is already decided by the shape.
    let shape: IconShape

    var pixelWidth: Int { image.width }
    var pixelHeight: Int { image.height }
    var longestEdge: Int { max(pixelWidth, pixelHeight) }

    /// Whether the image carries alpha the icon will actually benefit from.
    ///
    /// Asked of the *pixels*, not the format. `IconImport` re-encodes everything it
    /// accepts to PNG, so by the time an image reaches here it always has an alpha
    /// channel — a JPEG's is simply opaque from edge to edge. The question worth
    /// answering is whether that channel does anything, which is exactly what the
    /// shape classifier measures: `fullBleed` means alpha covers the whole canvas
    /// with hard corners, i.e. a rectangle however it looks.
    ///
    /// This is the single most common disappointment in taking an icon off the web,
    /// so it is said plainly rather than left to be discovered in the Dock.
    var hasUsefulTransparency: Bool { shape != .fullBleed && shape != .empty }

    var isBigEnough: Bool { longestEdge >= PickedWebImage.preferredLongestEdge }

    /// How the artwork sits in its canvas, in words.
    ///
    /// Not `IconShape.label`: that is phrased for Zap's Settings row, where it
    /// describes *a bundle's own* artwork ("Original artwork (free-form)"). Nothing
    /// about an image pulled off Google is "original artwork".
    var shapeDescription: String {
        switch shape {
        case .freeform: return "Free-form shape"
        case .roundedSquare: return "Rounded square"
        case .fullBleed: return "Fills the whole canvas"
        case .empty: return "No artwork found"
        }
    }

    /// What to tell the user before they commit, worst first.
    var notes: [Note] {
        var found: [Note] = []

        if !isBigEnough {
            found.append(Note(
                level: .warning,
                text: "\(pixelWidth)×\(pixelHeight) — icons look best at "
                    + "\(PickedWebImage.preferredLongestEdge) px or more. "
                    + (resolverNote ?? "This will look soft at large sizes.")))
        } else if !isOriginal {
            found.append(Note(
                level: .info,
                text: resolverNote ?? "Taken from a preview image rather than the original."))
        }

        // `shape == .fullBleed`, not `!hasUsefulTransparency`. The latter is also true
        // for `.empty`, and an image with no artwork is *entirely* transparent — the
        // opposite of a rectangle. Saying both of it, as this did, reads like Pict is
        // guessing, which is the one impression a preview cannot afford to give.
        if shape == .fullBleed {
            found.append(Note(
                level: .warning,
                text: "No transparency — this will appear as a rectangle rather than "
                    + "taking the shape of the artwork."))
        }

        if shape == .empty {
            found.append(Note(
                level: .warning,
                text: "Pict can't find any artwork in this image."))
        }

        let ratio = Double(pixelWidth) / Double(max(pixelHeight, 1))
        if ratio < IconImageValidator.Limits.minimumAspectRatio
            || ratio > IconImageValidator.Limits.maximumAspectRatio {
            found.append(Note(level: .warning,
                              text: "Far from square, so it will be letterboxed in the row."))
        }

        if found.isEmpty {
            found.append(Note(level: .good, text: "Looks like a good icon."))
        }
        return found
    }

    struct Note: Identifiable {
        let id = UUID()
        let level: Level
        let text: String

        enum Level {
            case good, info, warning

            var symbol: String {
                switch self {
                case .good: return "checkmark.circle.fill"
                case .info: return "info.circle.fill"
                case .warning: return "exclamationmark.triangle.fill"
                }
            }
        }
    }
}
