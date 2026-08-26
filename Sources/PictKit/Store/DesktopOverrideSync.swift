#if os(Linux)
import Foundation

/// Applies the shared icon store to the desktop system-wide (LP-15) — the Linux-only
/// "superpower" the freedesktop stack allows and macOS never did.
///
/// For every store entry keyed to a `.desktop` file (`app:` kind, a `…​.desktop` path),
/// it regenerates a shadowing copy at `$XDG_DATA_HOME/applications/<id>.desktop` — the
/// *current system entry with only `Icon=` replaced* by the store PNG's absolute path —
/// which `$XDG_DATA_HOME` wins in ID resolution, so GNOME Shell's dash/switcher honor it
/// and it survives app updates (see `docs/linux-port.md` §Applying icons system-wide).
///
/// Two safety rules from the plan:
/// - **Don't fork stale copies.** Every override is regenerated from the *current* system
///   entry each sync, and one no longer backed by a store entry is removed.
/// - **Never touch what Pict didn't write.** Every generated file carries
///   `X-Pict-Managed=true`; the removal pass only ever deletes files that carry it, so a
///   hand-authored `.desktop` in the same directory is left alone.
public struct DesktopOverrideSync {

    private let store: IconStore
    private let overridesDirectory: URL
    private let fileManager: FileManager

    public init(store: IconStore,
                overridesDirectory: URL = DesktopOverrideSync.defaultOverridesDirectory(),
                fileManager: FileManager = .default) {
        self.store = store
        self.overridesDirectory = overridesDirectory
        self.fileManager = fileManager
    }

    /// `$XDG_DATA_HOME/applications` — the per-user applications directory that wins
    /// desktop-file ID resolution. Mirrors how `IconStoreLocation.defaultDirectory()`
    /// derives `$XDG_DATA_HOME/Pict`.
    public static func defaultOverridesDirectory(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("applications", isDirectory: true)
    }

    /// What one sync did.
    public struct Summary: Equatable {
        /// Overrides written or rewritten (a regenerated file whose contents were already
        /// current is not counted).
        public var written: Int
        /// Stale Pict-managed overrides removed.
        public var removed: Int
        /// Desktop-keyed entries skipped because their system entry is gone or they carry
        /// no image.
        public var skipped: Int

        public init(written: Int = 0, removed: Int = 0, skipped: Int = 0) {
            self.written = written
            self.removed = removed
            self.skipped = skipped
        }
    }

    /// Regenerates every override and removes stale ones. Best-effort per entry: one
    /// unreadable system file or unwritable override never aborts the rest.
    @discardableResult
    public func sync() -> Summary {
        var summary = Summary()
        try? fileManager.createDirectory(at: overridesDirectory, withIntermediateDirectories: true)

        var wanted = Set<String>()   // absolute paths of overrides we (re)generated
        for (key, entry) in store.entries where isDesktopKey(key) {
            guard entry.origin.needsImage, let image = entry.image else { summary.skipped += 1; continue }
            let systemPath = key.value
            guard let systemText = try? String(contentsOfFile: systemPath, encoding: .utf8) else {
                // The app is gone (or the entry is unreadable): don't regenerate, and let
                // the removal pass reap any override that was pointing at it.
                summary.skipped += 1
                continue
            }
            let iconPath = store.entriesDirectory.appendingPathComponent(image)
                .standardizedFileURL.path
            let overrideURL = overridesDirectory.appendingPathComponent(overrideFilename(forSystemPath: systemPath))
            wanted.insert(overrideURL.standardizedFileURL.path)

            let newContent = DesktopEntryRewriter.rewrite(systemText, iconPath: iconPath)
            if writeIfChanged(newContent, to: overrideURL) { summary.written += 1 }
        }

        summary.removed = removeStaleOverrides(keeping: wanted)
        return summary
    }

    // MARK: - Private

    /// A store key that names a `.desktop` file — the Linux spelling of "an application"
    /// the `pict` CLI stores under the `app:` kind.
    private func isDesktopKey(_ key: IconEntryKey) -> Bool {
        key.kind == .app && key.value.lowercased().hasSuffix(".desktop")
    }

    /// The override's filename: the system entry's freedesktop **desktop-file ID** with
    /// its `.desktop` suffix — the path under an `applications/` directory with `/` → `-`
    /// (so a subdirectory'd entry shadows correctly), falling back to the bare basename.
    private func overrideFilename(forSystemPath path: String) -> String {
        let marker = "/applications/"
        if let range = path.range(of: marker) {
            return String(path[range.upperBound...]).replacingOccurrences(of: "/", with: "-")
        }
        return (path as NSString).lastPathComponent
    }

    /// Writes `content` to `url` only when it differs from what's already there, so a
    /// no-op sync doesn't churn mtimes (and file watchers). Returns whether it wrote.
    private func writeIfChanged(_ content: String, to url: URL) -> Bool {
        if let existing = try? String(contentsOf: url, encoding: .utf8), existing == content {
            return false
        }
        do {
            try content.data(using: .utf8)?.write(to: url, options: .atomic)
            return true
        } catch {
            NSLog("PictKit: couldn't write desktop override %@: %@", url.path, error.localizedDescription)
            return false
        }
    }

    /// Removes every Pict-managed override not in `keeping`. A file we didn't write (no
    /// `X-Pict-Managed=true`) is never touched, even if it collides with an id we manage.
    private func removeStaleOverrides(keeping wanted: Set<String>) -> Int {
        guard let names = try? fileManager.contentsOfDirectory(atPath: overridesDirectory.path) else {
            return 0
        }
        var removed = 0
        for name in names where name.lowercased().hasSuffix(".desktop") {
            let url = overridesDirectory.appendingPathComponent(name)
            if wanted.contains(url.standardizedFileURL.path) { continue }
            guard let content = try? String(contentsOf: url, encoding: .utf8),
                  DesktopEntryRewriter.isManaged(content) else { continue }
            if (try? fileManager.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }
}
#endif
