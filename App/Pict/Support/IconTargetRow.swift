import AppKit
import PictKit

/// One thing the editor can give an icon to: an app, and later a file or a link.
///
/// Replaces Zap's `AppInfo`, which was a switcher's model — built from an
/// `NSRunningApplication`, identified by bundle identifier plus pid. Pict lists what
/// is *installed*, most of which is not running, so the identity has to come from
/// the thing on disk instead.
struct IconTargetRow: Identifiable, Hashable {

    /// What the store keys this by.
    let target: IconTarget
    /// What the row is labelled.
    let name: String
    /// Where it lives, when it has a location.
    let url: URL?
    /// The bundle identifier, for apps.
    let bundleIdentifier: String?

    /// Stable across reloads and unique per row, which a bundle identifier is not:
    /// site-specific-browser wrappers share one, and three rows collapsing into one
    /// `List` identity is how a click lands on the wrong app.
    var id: String { key?.serialized ?? name }

    var key: IconEntryKey? { IconEntryKey.storageKey(for: target) }

    /// The icon macOS would draw — the fallback shown while the resolver warms, and
    /// the picture the user is asking to replace.
    var systemIcon: NSImage? {
        guard let url else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    // MARK: Making one

    /// An application bundle on disk.
    init(applicationAt url: URL) {
        self.url = url
        self.bundleIdentifier = Bundle(url: url)?.bundleIdentifier
        self.target = .application(bundleURL: url, bundleIdentifier: bundleIdentifier)
        let stem = url.deletingPathExtension().lastPathComponent
        self.name = stem.isEmpty ? url.lastPathComponent : stem
    }

    /// A row for a stored entry whose target isn't where it said it was — an app
    /// since deleted or moved. Without it the user could never undo the override,
    /// which is the one thing they are certain to want when an icon is wrong.
    init(orphanedKey key: IconEntryKey) {
        switch key.kind {
        case .app:
            let url = URL(fileURLWithPath: key.value)
            self.url = url
            self.bundleIdentifier = nil
            self.target = .application(bundleURL: url, bundleIdentifier: nil)
            let stem = url.deletingPathExtension().lastPathComponent
            self.name = stem.isEmpty ? key.value : stem
        case .bundleID:
            let located = NSWorkspace.shared.urlForApplication(withBundleIdentifier: key.value)
            self.url = located
            self.bundleIdentifier = key.value
            self.target = .application(bundleURL: nil, bundleIdentifier: key.value)
            self.name = located.map { $0.deletingPathExtension().lastPathComponent } ?? key.value
        case .file:
            let url = URL(fileURLWithPath: key.value)
            self.url = url
            self.bundleIdentifier = nil
            self.target = .file(url)
            self.name = url.lastPathComponent
        case .url:
            let url = URL(string: key.value)
            self.url = url
            self.bundleIdentifier = nil
            self.target = url.map { IconTarget.link($0) }
                ?? .file(URL(fileURLWithPath: key.value))
            self.name = url?.host ?? key.value
        }
    }
}
