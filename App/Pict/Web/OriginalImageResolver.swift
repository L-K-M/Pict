import Foundation

/// Finds the full-size original behind a thumbnail.
///
/// The problem this exists for: in a search-results grid the pointer is over a
/// thumbnail, not the picture. Google serves those from `gstatic.com` at roughly
/// 200–300 px, which is under the 512 px an icon wants and would produce a visibly
/// soft result. Taking the thumbnail silently is the worst outcome — it looks like
/// the feature works and quietly makes bad icons.
///
/// **Deliberately not a scraper.** Everything here reads structure the page already
/// gave the browser: the enclosing link, and query parameters inside it. Nothing
/// parses a site's internal JSON, re-implements its layout, or issues a request the
/// user's click didn't imply. That keeps it from breaking every time a site
/// reshuffles its markup, and keeps it on the right side of "this is what a browser
/// does" — a person right-clicking one image they chose.
enum OriginalImageResolver {

    /// Hosts that only ever serve thumbnails, so a hit is proof the picked image is
    /// a proxy for something bigger even when the page didn't report a size.
    ///
    /// Suffix-matched against the host, so `encrypted-tbn0.gstatic.com` and
    /// `tbn2.gstatic.com` both match without listing every shard.
    private static let thumbnailHosts = [
        "gstatic.com",      // Google Images grid
        "bing.net",         // Bing's th.bing.com
        "ytimg.com",
    ]

    /// Query parameters that carry the original's address. These are the pattern
    /// used by image search result links — the destination is a viewer page, and the
    /// picture it will show is named in the URL.
    private static let originalParameters = ["imgurl", "mediaurl", "murl", "imgrefurl_img"]

    /// What to fetch for `picked`, and whether it is the original or a fallback.
    ///
    /// Order matters: an image already big enough is never second-guessed, because
    /// following a link off a perfectly good picture is how you end up downloading
    /// the wrong thing from a page that happened to wrap it.
    static func resolve(_ picked: PickedWebImage) -> Resolution {
        if picked.hasKnownSize && picked.isBigEnough {
            return Resolution(url: picked.imageURL, isOriginal: true, warning: nil)
        }

        if let original = original(from: picked) {
            return Resolution(url: original, isOriginal: true, warning: nil)
        }

        // Nothing better found. Take it, and say so — the alternative is refusing an
        // image the user can see and wants, which is worse than a soft icon they
        // chose knowingly.
        return Resolution(url: picked.imageURL, isOriginal: false,
                          warning: warning(for: picked))
    }

    /// The original's URL, from the structure around the thumbnail.
    static func original(from picked: PickedWebImage) -> URL? {
        guard let link = picked.linkURL else { return nil }

        // 1. The address is a parameter of the link — the image-search pattern.
        if let components = URLComponents(url: link, resolvingAgainstBaseURL: false),
           let items = components.queryItems {
            for name in originalParameters {
                if let value = items.first(where: { $0.name == name })?.value,
                   let url = URL(string: value), url.scheme != nil,
                   isFetchableImageURL(url) {
                    return url
                }
            }
        }

        // 2. The link points straight at an image file. Common on Wikimedia and on
        //    plain galleries, where the thumbnail links to the full-size upload.
        if isImagePath(link), isFetchableImageURL(link) {
            return link
        }

        return nil
    }

    /// Whether a URL is worth handing to the fetcher at all.
    private static func isFetchableImageURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// Whether the path looks like an image file. Extension-based, which is a hint
    /// rather than proof — the fetched bytes are sniffed and validated regardless, so
    /// a wrong guess here costs one request and a clear refusal, not a bad icon.
    static func isImagePath(_ url: URL) -> Bool {
        let extensions = ["png", "jpg", "jpeg", "gif", "webp", "svg", "tiff", "bmp", "heic"]
        return extensions.contains(url.pathExtension.lowercased())
    }

    /// Whether `url`'s host is a known thumbnail-only host.
    static func isThumbnailHost(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return thumbnailHosts.contains { host == $0 || host.hasSuffix(".\($0)") }
    }

    /// Why the picked image may disappoint, phrased for the caption under the row.
    private static func warning(for picked: PickedWebImage) -> String? {
        if picked.hasKnownSize && !picked.isBigEnough {
            return "That image is \(picked.naturalWidth)×\(picked.naturalHeight). "
                + "Icons look best at \(PickedWebImage.preferredLongestEdge) px or more — "
                + "opening the image itself and using that usually finds a bigger one."
        }
        if isThumbnailHost(picked.imageURL) {
            return "That looked like a search thumbnail and Pict couldn't find the "
                + "original. Opening the image itself usually finds a bigger one."
        }
        return nil
    }

    /// What to fetch, and what to say about it.
    struct Resolution: Equatable {
        let url: URL
        /// `false` when this is the thumbnail because nothing better was found.
        let isOriginal: Bool
        /// Non-nil when the user should be told the result may be soft. Not an
        /// error: the download still goes ahead.
        let warning: String?
    }
}
