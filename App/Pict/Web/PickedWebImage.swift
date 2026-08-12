import Foundation
import PictKit

/// An image the user right-clicked in the web browser, with everything needed to
/// decide what to actually fetch.
///
/// Carries the *rendered* size as well as the URL because the two disagree in the
/// case this feature runs into constantly: a search-results grid shows a 240 px
/// thumbnail of a 1024 px original, and the thumbnail is what the pointer is over.
/// `naturalWidth`/`naturalHeight` are the decoded pixel dimensions of the file the
/// browser actually loaded, so they answer "is this big enough?" honestly.
struct PickedWebImage: Equatable {

    /// The image the pointer was over — `currentSrc` where the page uses `srcset`,
    /// since that is the one the browser chose to display.
    let imageURL: URL
    /// The page it was on. Recorded as the credit, and the base for resolving a
    /// relative link.
    let pageURL: URL?
    /// `href` of the nearest enclosing link, when there is one. This is the road to
    /// the full-size original: in a results grid the thumbnail is nearly always
    /// wrapped in a link to either the image itself or a page showing it bigger.
    let linkURL: URL?
    /// Decoded pixel size of `imageURL`, or zero when the page hadn't finished
    /// loading it.
    let naturalWidth: Int
    let naturalHeight: Int

    /// The longest edge, which is what every size question here is really about.
    var longestEdge: Int { max(naturalWidth, naturalHeight) }

    /// Whether this is big enough to use without going looking for something better.
    ///
    /// The bar is `masterLongestEdge / 2` — 512 px. `UNJAILED.md §6.2` puts the
    /// master at 1024 and the floor for a *good* icon at 512; below that an icon is
    /// visibly soft at the sizes Zap's switcher draws. Deliberately far above
    /// `hardMinimumPixels` (64), which is the point at which an image is refused
    /// outright rather than the point at which it is any good.
    static let preferredLongestEdge = IconImageValidator.Limits.masterLongestEdge / 2

    var isBigEnough: Bool { longestEdge >= Self.preferredLongestEdge }

    /// Whether the size is known at all. A page that hands back zeroes is not
    /// telling us the image is small, only that it hasn't decoded it — so this is
    /// the difference between "too small, go find the original" and "no idea, just
    /// try it".
    var hasKnownSize: Bool { naturalWidth > 0 && naturalHeight > 0 }

    // MARK: Decoding the bridge's payload

    /// Builds one from the JavaScript bridge's dictionary, or `nil` when the payload
    /// has no usable image URL.
    ///
    /// Tolerant on purpose: everything except `src` is optional, because a page can
    /// legitimately have an image with no enclosing link, no size yet, or a
    /// `data:` URL. Refusing the whole payload over a missing extra would turn a
    /// usable right-click into a menu item that never appears.
    init?(payload: [String: Any]) {
        guard let source = payload["src"] as? String,
              let url = URL(string: source),
              // A relative or malformed src that parses to something without a
              // scheme is not fetchable, and `RemoteIconFetcher` would refuse it
              // later with a worse message.
              url.scheme != nil
        else { return nil }

        self.imageURL = url
        self.pageURL = (payload["page"] as? String).flatMap(URL.init(string:))
        self.linkURL = (payload["link"] as? String).flatMap(URL.init(string:))
        self.naturalWidth = (payload["width"] as? Int) ?? 0
        self.naturalHeight = (payload["height"] as? Int) ?? 0
    }

    /// Direct construction, for tests and for the resolver's rewrites.
    init(imageURL: URL, pageURL: URL? = nil, linkURL: URL? = nil,
         naturalWidth: Int = 0, naturalHeight: Int = 0) {
        self.imageURL = imageURL
        self.pageURL = pageURL
        self.linkURL = linkURL
        self.naturalWidth = naturalWidth
        self.naturalHeight = naturalHeight
    }
}
