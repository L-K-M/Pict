import XCTest
import PictKit
@testable import Pict

/// What the alert says. These are the only words the user gets when an icon
/// doesn't take, now that the caption is gone, so each one has to name the app it
/// concerns and say what happened to it.
final class IconProblemTests: XCTestCase {

    private let row = IconTargetRow(
        applicationAt: URL(fileURLWithPath: "/Applications/Nextcloud Talk.app"))

    func testRejectionKeepsTheReasonAndNamesTheApp() {
        let problem = IconProblem.rejected(.tooSmall(width: 32, height: 32), row: row)
        XCTAssertTrue(problem.message.contains("32×32"))
        XCTAssertTrue(problem.message.contains("Nextcloud Talk"))
        // Says what became of the icon, not only what was wrong with the file.
        XCTAssertTrue(problem.message.contains("unchanged"))
    }

    /// The reason an SVG wouldn't render reaches the alert intact — it is routed
    /// through `Rejection` on the way, which must not flatten it.
    func testSVGRenderFailureReachesTheAlert() {
        let problem = IconProblem.rejected(
            .svgNotRendered(reason: SVGRasterizer.RasterizeError.timedOut.message), row: row)
        XCTAssertTrue(problem.message.contains(SVGRasterizer.RasterizeError.timedOut.message))
    }

    func testEveryCaseHasATitleAndAMessage() {
        let problems = [
            IconProblem.rejected(.unreadable, row: row),
            .unfetchableLink(row: row),
            .fetchFailed("The server didn't answer.", row: row),
            .alreadyInFlight(row: row),
            .searchFailed("HTTP 503.", provider: "Iconify"),
            .previewsUnavailable(provider: "Iconify"),
        ]
        for problem in problems {
            XCTAssertFalse(problem.title.isEmpty)
            XCTAssertFalse(problem.message.isEmpty)
            // A title that ends in a full stop reads as a sentence fragment in the
            // alert's bold line; these are labels.
            XCTAssertFalse(problem.title.hasSuffix("."), "title should not end in a period: \(problem.title)")
        }
    }

    func testAppSpecificCasesNameTheApp() {
        let problems = [
            IconProblem.rejected(.unreadable, row: row),
            .unfetchableLink(row: row),
            .fetchFailed("The server didn't answer.", row: row),
            .alreadyInFlight(row: row),
        ]
        for problem in problems {
            XCTAssertTrue(problem.message.contains("Nextcloud Talk"),
                          "should name the app: \(problem.message)")
        }
    }

    func testSearchFailureNamesTheProvider() {
        let problem = IconProblem.searchFailed("HTTP 503.", provider: "Iconify")
        XCTAssertTrue(problem.title.contains("Iconify"))
        XCTAssertTrue(problem.message.contains("HTTP 503."))
    }
}
