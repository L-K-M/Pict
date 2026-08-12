import Foundation
import PictKit
import XCTest
@testable import Pict

/// Turning a right-click into something worth downloading.
///
/// The case that matters throughout: in a search-results grid the pointer is over a
/// ~240 px thumbnail of a 1024 px picture. Taking the thumbnail silently is the
/// worst outcome available — it looks like the feature worked and quietly produces a
/// soft icon.
final class WebImagePickTests: XCTestCase {

    private func url(_ string: String) -> URL { URL(string: string)! }

    // MARK: Decoding the bridge payload

    func testAPayloadWithAnImageDecodes() throws {
        let picked = try XCTUnwrap(PickedWebImage(payload: [
            "src": "https://example.com/icon.png",
            "page": "https://example.com/gallery",
            "link": "https://example.com/full.png",
            "width": 1024, "height": 1024,
        ]))
        XCTAssertEqual(picked.imageURL, url("https://example.com/icon.png"))
        XCTAssertEqual(picked.pageURL, url("https://example.com/gallery"))
        XCTAssertEqual(picked.linkURL, url("https://example.com/full.png"))
        XCTAssertEqual(picked.longestEdge, 1024)
    }

    /// Tolerant on purpose: an image with no enclosing link and no decoded size yet
    /// is still an image. Refusing the payload over a missing extra would turn a
    /// usable right-click into a menu item that never appears.
    func testEverythingExceptTheSourceIsOptional() throws {
        let picked = try XCTUnwrap(PickedWebImage(payload: ["src": "https://example.com/i.png"]))
        XCTAssertNil(picked.pageURL)
        XCTAssertNil(picked.linkURL)
        XCTAssertFalse(picked.hasKnownSize)
    }

    func testAnEmptyPayloadIsRejected() {
        XCTAssertNil(PickedWebImage(payload: [:]))
    }

    /// The bridge resolves against `document.baseURI`, so anything still relative by
    /// the time it arrives is malformed — and would fail later with a worse message.
    func testASchemelessSourceIsRejected() {
        XCTAssertNil(PickedWebImage(payload: ["src": "/images/icon.png"]))
    }

    // MARK: Big enough?

    func testSizeIsJudgedOnTheLongestEdge() {
        let wide = PickedWebImage(imageURL: url("https://e.com/a.png"),
                                  naturalWidth: 1024, naturalHeight: 200)
        XCTAssertEqual(wide.longestEdge, 1024)
        XCTAssertTrue(wide.isBigEnough)
    }

    func testAThumbnailSizedImageIsNotBigEnough() {
        let thumb = PickedWebImage(imageURL: url("https://e.com/a.png"),
                                   naturalWidth: 240, naturalHeight: 240)
        XCTAssertTrue(thumb.hasKnownSize)
        XCTAssertFalse(thumb.isBigEnough)
    }

    /// "No size reported" must not read as "too small" — one sends Pict looking for
    /// an original that may not exist, the other is just an undecoded image.
    func testAnUnknownSizeIsNotTreatedAsSmall() {
        let unknown = PickedWebImage(imageURL: url("https://e.com/a.png"))
        XCTAssertFalse(unknown.hasKnownSize)
    }

    /// The bar is well above the point at which an image is refused: 64 px is
    /// "unusable", 512 is "good". Picking the wrong one here would either accept
    /// mush or reject most of the web.
    func testThePreferredSizeSitsWellAboveTheHardFloor() {
        XCTAssertEqual(PickedWebImage.preferredLongestEdge,
                       IconImageValidator.Limits.masterLongestEdge / 2)
        XCTAssertGreaterThan(PickedWebImage.preferredLongestEdge,
                             IconImageValidator.Limits.hardMinimumPixels)
    }

    // MARK: Resolving to the original

    func testAnImageThatIsAlreadyBigIsUsedUntouched() {
        let big = PickedWebImage(imageURL: url("https://e.com/big.png"),
                                 linkURL: url("https://e.com/somewhere-else"),
                                 naturalWidth: 1024, naturalHeight: 1024)
        let resolved = OriginalImageResolver.resolve(big)
        XCTAssertEqual(resolved.url, big.imageURL)
        XCTAssertTrue(resolved.isOriginal)
        XCTAssertNil(resolved.warning)
    }

    /// The Google Images shape: a gstatic thumbnail wrapped in a link that names the
    /// real picture in `imgurl`.
    func testAThumbnailResolvesThroughItsLinkParameter() {
        let picked = PickedWebImage(
            imageURL: url("https://encrypted-tbn0.gstatic.com/images?q=tbn:abc"),
            pageURL: url("https://www.google.com/search?q=safari"),
            linkURL: url("https://www.google.com/imgres?imgurl=https%3A%2F%2Fcdn.example.com%2Fsafari-1024.png&imgrefurl=https%3A%2F%2Fexample.com"),
            naturalWidth: 240, naturalHeight: 240)

        let resolved = OriginalImageResolver.resolve(picked)
        XCTAssertEqual(resolved.url, url("https://cdn.example.com/safari-1024.png"))
        XCTAssertTrue(resolved.isOriginal)
        XCTAssertNil(resolved.warning)
    }

    /// The gallery shape: the thumbnail links straight at the full-size upload.
    func testAThumbnailLinkingDirectlyAtAnImageResolves() {
        let picked = PickedWebImage(imageURL: url("https://e.com/thumb/safari.png"),
                                    linkURL: url("https://e.com/full/safari.png"),
                                    naturalWidth: 200, naturalHeight: 200)
        let resolved = OriginalImageResolver.resolve(picked)
        XCTAssertEqual(resolved.url, url("https://e.com/full/safari.png"))
        XCTAssertTrue(resolved.isOriginal)
    }

    /// A link to a *page* is not a link to a picture. Following it would download
    /// HTML and refuse it as "not an image", which blames the wrong thing.
    func testALinkToAPageIsNotMistakenForTheOriginal() {
        let picked = PickedWebImage(imageURL: url("https://e.com/thumb.png"),
                                    linkURL: url("https://e.com/articles/safari"),
                                    naturalWidth: 200, naturalHeight: 200)
        let resolved = OriginalImageResolver.resolve(picked)
        XCTAssertEqual(resolved.url, picked.imageURL, "should have fallen back")
        XCTAssertFalse(resolved.isOriginal)
        XCTAssertNotNil(resolved.warning)
    }

    /// The fallback is take-and-warn, not refuse. The picture was valid and the user
    /// chose it; overruling them about their own icon is worse than a soft one they
    /// were warned about.
    func testASmallImageWithNoLinkIsTakenWithAWarning() throws {
        let picked = PickedWebImage(imageURL: url("https://e.com/small.png"),
                                    naturalWidth: 128, naturalHeight: 128)
        let resolved = OriginalImageResolver.resolve(picked)
        XCTAssertEqual(resolved.url, picked.imageURL)
        XCTAssertFalse(resolved.isOriginal)
        let warning = try XCTUnwrap(resolved.warning)
        XCTAssertTrue(warning.contains("128×128"), warning)
    }

    /// Never follow a link off an image that was already fine — that is how you
    /// download the wrong picture from a page that merely happened to wrap it.
    func testABigImageIsNotSecondGuessedByItsLink() {
        let picked = PickedWebImage(
            imageURL: url("https://e.com/perfect-1024.png"),
            linkURL: url("https://e.com/imgres?imgurl=https%3A%2F%2Fe.com%2Fwrong.png"),
            naturalWidth: 1024, naturalHeight: 1024)
        XCTAssertEqual(OriginalImageResolver.resolve(picked).url,
                       url("https://e.com/perfect-1024.png"))
    }

    /// A `javascript:` or `file:` address reached through `imgurl` must not become a
    /// fetch target.
    func testANonWebOriginalIsIgnored() {
        let picked = PickedWebImage(
            imageURL: url("https://e.com/thumb.png"),
            linkURL: url("https://e.com/imgres?imgurl=file%3A%2F%2F%2Fetc%2Fpasswd"),
            naturalWidth: 200, naturalHeight: 200)
        let resolved = OriginalImageResolver.resolve(picked)
        XCTAssertEqual(resolved.url, picked.imageURL)
        XCTAssertFalse(resolved.isOriginal)
    }

    // MARK: Thumbnail hosts

    func testThumbnailHostsMatchTheirShards() {
        XCTAssertTrue(OriginalImageResolver.isThumbnailHost(
            url("https://encrypted-tbn0.gstatic.com/images?q=x")))
        XCTAssertTrue(OriginalImageResolver.isThumbnailHost(url("https://tbn2.gstatic.com/i")))
        XCTAssertFalse(OriginalImageResolver.isThumbnailHost(url("https://example.com/i.png")))
    }

    /// Suffix matching must not be substring matching: a host that merely *ends* in
    /// something similar is a different site.
    func testASimilarlyNamedHostIsNotAThumbnailHost() {
        XCTAssertFalse(OriginalImageResolver.isThumbnailHost(url("https://notgstatic.com/i.png")))
        XCTAssertFalse(OriginalImageResolver.isThumbnailHost(url("https://gstatic.com.evil.net/i")))
    }

    /// An unknown size on a known thumbnail host still earns a warning — the host is
    /// the evidence when the page didn't report dimensions.
    func testAThumbnailHostWarnsEvenWithoutASize() throws {
        let picked = PickedWebImage(imageURL: url("https://encrypted-tbn0.gstatic.com/images?q=x"))
        let resolved = OriginalImageResolver.resolve(picked)
        XCTAssertFalse(resolved.isOriginal)
        XCTAssertNotNil(try XCTUnwrap(resolved.warning))
    }

    func testImagePathsAreRecognisedByExtension() {
        XCTAssertTrue(OriginalImageResolver.isImagePath(url("https://e.com/a.PNG")))
        XCTAssertTrue(OriginalImageResolver.isImagePath(url("https://e.com/a.svg")))
        XCTAssertFalse(OriginalImageResolver.isImagePath(url("https://e.com/a")))
        XCTAssertFalse(OriginalImageResolver.isImagePath(url("https://e.com/a.html")))
    }
}
