import Foundation
import XCTest
@testable import Pict

/// The one field that is both an address bar and a search box.
///
/// The whole point of the browser being generic is that a user can leave the
/// curated sources — so "did they type a place or a thing?" is load-bearing, and
/// getting it wrong either strands them on a homepage or tries to resolve
/// "safari icon" as a hostname.
final class WebImageSourceTests: XCTestCase {

    private let google = WebImageSource.all.first { $0.id == "google-images" }!
    private let macosicons = WebImageSource.default

    // MARK: Address or query

    func testAFullURLIsTreatedAsAnAddress() throws {
        let url = try XCTUnwrap(WebImageSource.destination(
            for: "https://example.com/icons", on: macosicons))
        XCTAssertEqual(url.absoluteString, "https://example.com/icons")
    }

    func testABareHostBecomesAnAddress() throws {
        let url = try XCTUnwrap(WebImageSource.destination(for: "macosicons.com", on: google))
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "macosicons.com")
    }

    /// The discriminator. A dot alone can't mean "address" — plenty of searches
    /// contain one — so a phrase with a space stays a search.
    func testAPhraseWithASpaceIsASearchEvenWithADot() throws {
        let url = try XCTUnwrap(WebImageSource.destination(
            for: "safari 2.0 icon", on: google))
        XCTAssertNotEqual(url.host, "safari")
        XCTAssertTrue(url.absoluteString.contains("google.com"),
                      "should have searched, got \(url)")
    }

    func testPlainWordsAreSearched() throws {
        let url = try XCTUnwrap(WebImageSource.destination(for: "terminal", on: google))
        XCTAssertTrue(url.absoluteString.contains("q=terminal"), url.absoluteString)
    }

    func testEmptyInputGoesToTheSourcesHomepage() throws {
        let url = try XCTUnwrap(WebImageSource.destination(for: "   ", on: macosicons))
        XCTAssertEqual(url, macosicons.url)
    }

    /// A non-http scheme is not an address this browser should follow — `file:` and
    /// `javascript:` in particular. Treated as a query, which is harmless.
    func testANonWebSchemeIsNotFollowed() throws {
        let url = try XCTUnwrap(WebImageSource.destination(
            for: "file:///etc/passwd", on: google))
        XCTAssertNotEqual(url.scheme, "file")
    }

    // MARK: The transparency filter

    /// `UNJAILED.md §5.3` calls `ic:trans` "the whole ballgame" — it is what makes
    /// results usable as icons rather than a page of opaque screenshots. Losing it
    /// on the second search would make the first result set look like a fluke.
    func testGoogleSearchesKeepTheTransparencyFilter() throws {
        XCTAssertTrue(google.url.absoluteString.contains("tbs=ic:trans"),
                      "the starting URL lost the filter")

        let searched = try XCTUnwrap(WebImageSource.searchURL(for: "safari", on: google))
        XCTAssertTrue(searched.absoluteString.contains("tbs=ic:trans"),
                      "a typed search lost the filter: \(searched)")
    }

    func testQueriesAreEscaped() throws {
        let url = try XCTUnwrap(WebImageSource.searchURL(for: "top drawer", on: google))
        XCTAssertFalse(url.absoluteString.contains(" "), url.absoluteString)
        XCTAssertNotNil(URL(string: url.absoluteString))
    }

    // MARK: The sources themselves

    func testEverySourceHasAUsableStartingURL() {
        for source in WebImageSource.all {
            XCTAssertEqual(source.url.scheme, "https", "\(source.id) is not https")
            XCTAssertNotNil(source.url.host, "\(source.id) has no host")
            XCTAssertFalse(source.name.isEmpty)
            XCTAssertFalse(source.note.isEmpty, "\(source.id) has no note to explain it")
        }
    }

    func testEverySourceCanSearch() throws {
        for source in WebImageSource.all {
            let url = try XCTUnwrap(WebImageSource.searchURL(for: "safari", on: source),
                                    "\(source.id) can't search")
            XCTAssertNotNil(url.host)
        }
    }

    func testSourceIdentifiersAreUnique() {
        XCTAssertEqual(Set(WebImageSource.all.map(\.id)).count, WebImageSource.all.count)
    }

    /// macOSicons leads because it is the only live corpus that *is* this problem —
    /// `UNJAILED.md §5.2` rates it ★★★★★ and everything else lower. It was rejected
    /// there only because its API allows fifty requests a month; browsing has no
    /// quota, which is the reason this feature can use it at all.
    func testTheDefaultSourceIsTheOnePurposeBuiltForIcons() {
        XCTAssertEqual(WebImageSource.default.id, "macosicons")
        XCTAssertEqual(WebImageSource.all.first?.id, "macosicons")
    }
}
