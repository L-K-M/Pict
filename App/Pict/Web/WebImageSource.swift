import Foundation

/// A starting point for the web-image browser.
///
/// The browser works on any site — the user can type an address, and following a
/// link off one of these is expected. These exist so the window opens somewhere
/// useful rather than blank, and so the good corpora for *this* problem are the
/// ones a person finds first.
///
/// Why a list at all, rather than opening straight on Google Images: Zap's
/// `UNJAILED.md §5.2` surveyed the field and found no general image-search API left
/// to build on, then named **macOSicons** the best corpus for this problem and
/// rejected it too — its free API tier is fifty requests a *month*. Browsing a site
/// costs no key and has no quota, so the one source that was unreachable through an
/// API is reachable this way. Pinning the feature to Google alone would have thrown
/// that away, and would have staked the whole thing on a site that actively
/// discourages embedded browsers.
struct WebImageSource: Identifiable, Hashable {

    let id: String
    /// Shown in the picker.
    let name: String
    /// One line under it: what this corpus is, so the choice is informed.
    let note: String
    let url: URL

    /// Best first. Order is the recommendation.
    static let all: [WebImageSource] = [
        WebImageSource(
            id: "macosicons",
            name: "macOSicons",
            note: "Community-drawn Mac app icons, already un-squircled",
            url: URL(string: "https://macosicons.com/#/")!),
        WebImageSource(
            id: "google-images",
            name: "Google Images",
            note: "Everything, filtered to transparent backgrounds",
            // `tbs=ic:trans` is Google Images' transparency filter. `UNJAILED.md §5.3`
            // calls it "the whole ballgame": it is what turns a page of opaque JPEG
            // screenshots into a page of alpha-channel PNGs, and it is the
            // machine-checkable form of "is this usable as an icon?".
            url: URL(string: "https://www.google.com/search?q=icon&udm=2&tbs=ic:trans")!),
        WebImageSource(
            id: "openverse",
            name: "Openverse",
            note: "Openly licensed images, with the licence stated",
            url: URL(string: "https://openverse.org/search/image?q=icon")!),
        WebImageSource(
            id: "wikimedia",
            name: "Wikimedia Commons",
            note: "Free media — good for logos and marks",
            url: URL(string: "https://commons.wikimedia.org/w/index.php?search=logo+svg")!),
    ]

    static let `default` = all[0]

    /// Where a typed query goes.
    ///
    /// Anything that parses as an http(s) address is treated as one, so the field
    /// doubles as an address bar and the browser is not walled into these four
    /// sites. Everything else is searched on `source`.
    static func destination(for typed: String, on source: WebImageSource) -> URL? {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return source.url }

        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https", url.host != nil {
            return url
        }
        // A bare host typed without a scheme — "macosicons.com". Requires a dot and
        // no spaces, so "safari icon" stays a search rather than becoming a hostname.
        if !trimmed.contains(" "), trimmed.contains("."),
           let url = URL(string: "https://\(trimmed)"), url.host != nil {
            return url
        }
        return searchURL(for: trimmed, on: source)
    }

    /// The site's own search for `query`.
    ///
    /// Each site's search lives at a different address, and sending a query to the
    /// wrong one silently lands on a homepage — so this is a per-source detail
    /// rather than one URL template with the host swapped.
    static func searchURL(for query: String, on source: WebImageSource) -> URL? {
        guard let escaped = query.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed) else { return nil }

        switch source.id {
        case "macosicons":
            return URL(string: "https://macosicons.com/#/?search=\(escaped)")
        case "google-images":
            // Keeps the transparency filter across searches — losing it on the
            // second query would make the first result set look like a fluke.
            return URL(string: "https://www.google.com/search?q=\(escaped)&udm=2&tbs=ic:trans")
        case "openverse":
            return URL(string: "https://openverse.org/search/image?q=\(escaped)")
        case "wikimedia":
            return URL(string: "https://commons.wikimedia.org/w/index.php?search=\(escaped)")
        default:
            return source.url
        }
    }
}
