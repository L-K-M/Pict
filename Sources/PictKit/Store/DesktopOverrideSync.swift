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
        // Fall back to the spec's `$HOME/.local/share`, not a temp dir: an override under
        // `$TMPDIR/applications` isn't on the desktop-file search path (so it would silently
        // have no effect) and is ephemeral. The primary path mirrors IconStoreLocation.
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent(".local/share", isDirectory: true)
        return base.appendingPathComponent("applications", isDirectory: true)
    }

    /// What one sync did.
    public struct Summary: Equatable {
        /// Overrides written or rewritten (a regenerated file whose contents were already
        /// current is not counted).
        public var written: Int
        /// Stale Pict-managed overrides removed.
        public var removed: Int
        /// Desktop-keyed entries skipped: no image, a missing / unreadable / corrupt system
        /// entry, a desktop-file-id collision lost to another entry, or a refused or failed
        /// write (a hand-authored file at our id, or an I/O error).
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

        // First pass: resolve, for each override id, the winning (system path, content).
        // Two entries can resolve to the same id, and the store is a dictionary — iteration
        // order is randomized per process. Deciding the winner up front (lowest system path)
        // and writing only in the second pass makes both the result and the mtime stable
        // across syncs; writing as we go would let the loser write and the winner overwrite
        // within one sync, churning the file whenever the loser was iterated first.
        var winners: [String: (systemPath: String, content: String)] = [:]
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
            // If the store index and its entries dir have drifted (a partial delete, an
            // interrupted copy), don't point an override at a PNG that isn't there — skip it,
            // and let the removal pass reap any stale override so the system icon returns.
            guard fileManager.fileExists(atPath: iconPath) else { summary.skipped += 1; continue }
            let newContent = DesktopEntryRewriter.rewrite(systemText, iconPath: iconPath)
            // A system entry we couldn't rewrite (no [Desktop Entry] group — corrupt, empty,
            // or an icon path with a line break) must not be written unmarked, since it could
            // never be reaped. Skip it, and don't claim its id — so a stale one is still reaped.
            guard DesktopEntryRewriter.isManaged(newContent) else { summary.skipped += 1; continue }

            let overrideName = overrideFilename(forSystemPath: systemPath)
            if let existing = winners[overrideName] {
                if systemPath < existing.systemPath { winners[overrideName] = (systemPath, newContent) }
                summary.skipped += 1   // exactly one of the colliders loses its own override
            } else {
                winners[overrideName] = (systemPath, newContent)
            }
        }

        // Second pass: write each id's winner once.
        var wanted = Set<String>()         // absolute paths of overrides we (re)generated
        for (overrideName, winner) in winners {
            let overrideURL = overridesDirectory.appendingPathComponent(overrideName)
            wanted.insert(overrideURL.standardizedFileURL.path)
            switch writeIfChanged(winner.content, to: overrideURL) {
            case .written: summary.written += 1
            // A refusal (a hand-authored file at our id) or an I/O failure means the entry
            // wasn't applied — count it as skipped so the summary isn't a misleading "0/0/0".
            case .refused, .failed: summary.skipped += 1
            case .unchanged: break
            }
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

    /// The override's filename: the system entry's freedesktop **desktop-file ID** with its
    /// `.desktop` suffix — the path under an `applications/` directory with `/` → `-` (so a
    /// subdirectory'd entry like `applications/kde/foo.desktop` shadows as `kde-foo.desktop`,
    /// per the spec's "path relative to the data-dir's `applications/`, `/` → `-`" rule).
    ///
    /// For all realistic paths — every entry actually lives under some
    /// `$XDG_DATA_DIRS/applications` — the first `/applications/` is the data-dir boundary,
    /// so this matches the spec ID exactly. The bare-basename fallback only fires for a path
    /// that names no `applications/` component at all (e.g. a hand-typed
    /// `app:/opt/x/foo.desktop`); that is best-effort and could in principle shadow an
    /// unrelated app that happens to own the id `foo.desktop`. Resolving it precisely would
    /// mean matching against the live `$XDG_DATA_HOME`/`$XDG_DATA_DIRS` prefixes, which this
    /// type doesn't take (tests drive it against a temp tree) — deferred rather than
    /// widened here, since a store entry keyed outside every applications tree is unusual and
    /// the user pointed at that path explicitly.
    private func overrideFilename(forSystemPath path: String) -> String {
        let marker = "/applications/"
        if let range = path.range(of: marker) {
            return String(path[range.upperBound...]).replacingOccurrences(of: "/", with: "-")
        }
        return (path as NSString).lastPathComponent
    }

    /// The result of a `writeIfChanged` attempt, so `sync` can surface a refusal or an I/O
    /// failure as `skipped` rather than let it vanish into a "0 written, 0 skipped" line.
    private enum WriteOutcome { case written, unchanged, refused, failed }

    /// Writes `content` to `url` only when it differs from what's already there, so a
    /// no-op sync doesn't churn mtimes (and file watchers).
    ///
    /// Refuses to clobber a file Pict didn't write. An existing file at `url` that either
    /// carries no `X-Pict-Managed=true` marker *or can't be read back as UTF-8* (our own
    /// overrides always are) belongs to a hand-authored entry shadowing the same
    /// desktop-file id, and we leave it exactly as it is — matching the removal pass, which
    /// also never touches an unmarked file. The UTF-8 check is why we test existence
    /// explicitly first: `try? String(contentsOf:)` returns `nil` both for an absent file
    /// *and* for a present-but-undecodable one (a legacy-encoded `.desktop`), and reading
    /// the latter as "absent" would overwrite it — worse than churn, since the copy we'd
    /// write carries the marker, so a later `pict remove` + sync would then reap the user's
    /// own file outright.
    private func writeIfChanged(_ content: String, to url: URL) -> WriteOutcome {
        if fileManager.fileExists(atPath: url.path) {
            guard let existing = try? String(contentsOf: url, encoding: .utf8) else {
                NSLog("PictKit: refusing to overwrite an unreadable desktop file Pict didn't write: %@", url.path)
                return .refused
            }
            if existing == content { return .unchanged }
            guard DesktopEntryRewriter.isManaged(existing) else {
                NSLog("PictKit: refusing to overwrite a desktop file Pict didn't write: %@", url.path)
                return .refused
            }
        }
        do {
            try content.data(using: .utf8)?.write(to: url, options: .atomic)
            return .written
        } catch {
            NSLog("PictKit: couldn't write desktop override %@: %@", url.path, error.localizedDescription)
            return .failed
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
