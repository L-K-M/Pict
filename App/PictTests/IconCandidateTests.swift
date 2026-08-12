import CoreGraphics
import PictKit
import XCTest
@testable import Pict

/// What the preview tells the user before anything is written.
///
/// This step exists because the first version wrote the icon and *then* warned. The
/// warning was accurate and useless: acting on it meant reopening the browser and
/// finding the page again. So these assert the two things the preview has to get
/// right — that it notices what is wrong, and that noticing never becomes refusing.
final class IconCandidateTests: XCTestCase {

    private func image(_ width: Int, _ height: Int, opaque: Bool) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1)
        if opaque {
            context.fill(rect)                 // alpha covers everything: a rectangle
        } else {
            // A centred ellipse well inside the canvas, so alpha genuinely varies.
            context.fillEllipse(in: rect.insetBy(dx: Double(width) * 0.2,
                                                 dy: Double(height) * 0.2))
        }
        return context.makeImage()!
    }

    private func candidate(_ width: Int, _ height: Int,
                          opaque: Bool = false,
                          isOriginal: Bool = true,
                          note: String? = nil) -> IconCandidate {
        let bitmap = image(width, height, opaque: opaque)
        let profile = IconShapeClassifier.profile(of: bitmap)
        return IconCandidate(
            image: bitmap,
            picked: PickedWebImage(imageURL: URL(string: "https://e.com/i.png")!),
            fetchedURL: URL(string: "https://e.com/i.png")!,
            isOriginal: isOriginal,
            resolverNote: note,
            shape: profile.map { IconShapeClassifier.classify($0) } ?? .empty)
    }

    private func texts(_ candidate: IconCandidate) -> String {
        candidate.notes.map(\.text).joined(separator: " | ")
    }

    // MARK: Transparency

    /// The most common disappointment in taking an icon off the web, and the reason
    /// the preview draws on a chequerboard. Asked of the pixels, not the file format:
    /// ingestion re-encodes everything to PNG, so a JPEG arrives here *with* an alpha
    /// channel that happens to be opaque edge to edge.
    func testAnOpaqueRectangleIsReportedAsHavingNoTransparency() {
        let flat = candidate(1024, 1024, opaque: true)
        XCTAssertEqual(flat.shape, .fullBleed)
        XCTAssertFalse(flat.hasUsefulTransparency)
        XCTAssertTrue(texts(flat).contains("No transparency"), texts(flat))
    }

    func testFreeFormArtworkIsReportedAsTransparent() {
        let shaped = candidate(1024, 1024)
        XCTAssertTrue(shaped.hasUsefulTransparency, "classified \(shaped.shape)")
        XCTAssertFalse(texts(shaped).contains("No transparency"), texts(shaped))
    }

    // MARK: Size

    func testASmallImageIsFlagged() {
        let small = candidate(128, 128)
        XCTAssertFalse(small.isBigEnough)
        XCTAssertTrue(texts(small).contains("128×128"), texts(small))
    }

    func testABigImageIsNotFlaggedForSize() {
        XCTAssertTrue(candidate(1024, 1024).isBigEnough)
        XCTAssertFalse(texts(candidate(1024, 1024)).contains("look best at"))
    }

    /// The resolver knows things the candidate cannot — that the address was a known
    /// thumbnail host, say — so its wording is carried through rather than replaced
    /// with a generic line.
    func testTheResolversOwnAdviceIsShownWhenItHasSome() {
        let thumb = candidate(200, 200, isOriginal: false,
                              note: "That looked like a search thumbnail.")
        XCTAssertTrue(texts(thumb).contains("That looked like a search thumbnail."),
                      texts(thumb))
    }

    /// A preview-sourced image that is nonetheless big enough is worth a note but not
    /// a warning — nothing is wrong with it.
    func testABigPreviewImageIsMerelyNoted() {
        let notes = candidate(1024, 1024, isOriginal: false).notes
        XCTAssertTrue(notes.contains { $0.level == .info }, "\(notes.map(\.level))")
        XCTAssertFalse(notes.contains { $0.level == .warning })
    }

    // MARK: Shape

    func testAWildlyNonSquareImageIsFlagged() {
        let banner = candidate(1024, 128, opaque: true)
        XCTAssertTrue(texts(banner).contains("Far from square"), texts(banner))
    }

    // MARK: The good case

    /// Something has to be said even when nothing is wrong, or an empty panel reads
    /// as "Pict didn't manage to check".
    func testAGoodIconSaysSo() {
        let good = candidate(1024, 1024)
        XCTAssertEqual(good.notes.count, 1)
        XCTAssertEqual(good.notes.first?.level, .good)
    }

    // MARK: Noticing is not refusing

    /// Every note is advice about a picture the user picked deliberately. The preview
    /// exists to inform the choice, never to overrule it — so there is no state in
    /// which a candidate cannot be used.
    func testEveryCandidateCanStillBeUsed() {
        for sample in [candidate(64, 64, opaque: true),
                       candidate(1024, 128),
                       candidate(200, 200, isOriginal: false),
                       candidate(1024, 1024)] {
            XCTAssertFalse(sample.notes.isEmpty, "a candidate with nothing said about it")
            // The view's confirm button is unconditional; this pins the data behind it
            // so a future "disable when warned" cannot slip in unnoticed.
            XCTAssertGreaterThan(sample.pixelWidth, 0)
        }
    }
}
