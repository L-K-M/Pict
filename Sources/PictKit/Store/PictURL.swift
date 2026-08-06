import AppKit
import Foundation

/// Pict's URL scheme — how Zap, Jetty and Top Drawer hand an app over to be edited.
///
/// ```
/// pict://edit?target=app:/Applications/Safari.app
/// ```
///
/// One-way and stateless on purpose. The calling app fires the URL and forgets:
/// there is no reply to wait for, because the *store change* is the notification
/// (`IconStoreWatcher`), and nothing has to survive Pict being force-quit halfway.
public enum PictURL {

    public static let scheme = "pict"

    /// What a URL asked for.
    public enum Command: Equatable {
        /// Open the editor, selecting and revealing `target` if it is listed.
        case edit(IconEntryKey?)
    }

    /// The URL another app opens to edit `target`, or `nil` when the target has no
    /// key — an app with neither a location nor an identifier, which is not a thing
    /// anyone can override.
    public static func edit(_ target: IconTarget) -> URL? {
        guard let key = IconEntryKey.storageKey(for: target) else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = "edit"
        components.queryItems = [URLQueryItem(name: "target", value: key.serialized)]
        return components.url
    }

    /// A bare `pict://` — what a caller hands `NSWorkspace.urlForApplication(toOpen:)`
    /// to find out whether Pict is installed *without* launching it. That is what
    /// decides between offering "Change this app's icon everywhere…" and "Get Pict…".
    public static var probe: URL? { URL(string: "\(scheme)://") }

    // MARK: Finding Pict

    /// Where Pict is installed, or `nil` when it isn't — **without launching it**.
    ///
    /// This is what lets Zap, Jetty and Top Drawer offer "Change this app's icon
    /// everywhere…" only when it will work, and point at where to get Pict
    /// otherwise. Launch Services answers from its registration database, so asking
    /// costs nothing and starts nothing.
    public static func installedAppURL() -> URL? {
        guard let probe else { return nil }
        return NSWorkspace.shared.urlForApplication(toOpen: probe)
    }

    /// Where to send someone who hasn't got it.
    public static var homepage: URL? { URL(string: "https://github.com/L-K-M/Pict") }

    /// Opens Pict at `target`, or just opens Pict when there is nothing to select.
    /// Returns whether anything was opened.
    @discardableResult
    public static func open(selecting target: IconTarget?) -> Bool {
        guard let url = target.flatMap(edit) ?? probe else { return false }
        return NSWorkspace.shared.open(url)
    }

    /// Parses an incoming URL. Anything unrecognised opens the editor with nothing
    /// selected rather than being refused — a malformed deep link should land the
    /// user somewhere useful, not nowhere.
    public static func command(from url: URL) -> Command? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let serialized = components?.queryItems?
            .first(where: { $0.name == "target" })?.value
        return .edit(serialized.flatMap(IconEntryKey.init(serialized:)))
    }
}
