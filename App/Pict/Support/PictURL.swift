import Foundation
import PictKit

/// Pict's URL scheme — how Zap, Jetty and Top Drawer hand an app over to be edited.
///
/// ```
/// pict://edit?target=app:/Applications/Safari.app
/// ```
///
/// One-way and stateless on purpose. The calling app fires the URL and forgets:
/// there is no reply to wait for, because the *store change* is the notification
/// (`IconStoreWatcher`), and nothing has to survive Pict being force-quit halfway.
enum PictURL {

    public static let scheme = "pict"

    /// What a URL asked for.
    enum Command: Equatable {
        /// Open the editor, selecting and revealing `target` if it is listed.
        case edit(IconEntryKey?)
    }

    /// The URL another app opens to edit `target`, or `nil` when the target has no
    /// key — an app with neither a location nor an identifier, which is not a thing
    /// anyone can override.
    static func edit(_ target: IconTarget) -> URL? {
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
    static var probe: URL? { URL(string: "\(scheme)://") }

    /// Parses an incoming URL. Anything unrecognised opens the editor with nothing
    /// selected rather than being refused — a malformed deep link should land the
    /// user somewhere useful, not nowhere.
    static func command(from url: URL) -> Command? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let serialized = components?.queryItems?
            .first(where: { $0.name == "target" })?.value
        return .edit(serialized.flatMap(IconEntryKey.init(serialized:)))
    }
}
