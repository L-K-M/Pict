import AppKit
import PictKit

/// Finds the applications the editor lists.
///
/// Zap's Icons tab listed *running* apps plus whatever the store already had, which
/// is the gap `ANALYSIS.md §U5` files against `ExclusionsView` as well: the app you
/// want to fix is very often the one you are not running, and a list you have to
/// launch something to get into is a bad list. Pict is not a switcher and has no
/// reason to inherit that limitation, so it walks the applications directories.
enum InstalledApps {

    /// Where macOS keeps applications. `/System/Applications` matters more here than
    /// it looks: it is where Safari, Mail and the rest live on current systems, they
    /// are exactly the apps a de-jailer is wanted for, and every tool that works by
    /// writing into bundles gives up on them because SIP refuses the write. Pict only
    /// ever *reads* them, so they are ordinary rows.
    static let searchPaths: [URL] = {
        var paths = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Utilities", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true)
        ]
        if let home = FileManager.default.urls(for: .applicationDirectory, in: .userDomainMask).first {
            paths.append(home)
        }
        return paths
    }()

    /// How deep to descend. Vendors nest one level (`/Applications/Adobe…/App.app`);
    /// deeper than that and the walk starts finding helper apps inside bundles, which
    /// nobody wants a row for.
    private static let maximumDepth = 2

    /// Every application found, plus a row for any stored entry the walk didn't
    /// reach, sorted by name.
    ///
    /// Blocking — it stats a few thousand directory entries. Call it off the main
    /// thread; `load(store:completion:)` does that for you.
    static func all(store: IconStore, fileManager: FileManager = .default) -> [IconTargetRow] {
        var rows: [IconTargetRow] = []
        var seen: Set<String> = []

        for root in searchPaths {
            for url in applications(in: root, depth: 0, fileManager: fileManager) {
                let row = IconTargetRow(applicationAt: url)
                guard let id = row.key?.serialized, seen.insert(id).inserted else { continue }
                rows.append(row)
            }
        }

        // Anything the store knows about that the walk didn't find: an app installed
        // somewhere unusual, one since deleted, or a file or link given an icon by
        // another app. Without these the override is unreachable and so un-undoable.
        let covered = Set(rows.flatMap { row -> [String] in
            IconEntryKey.lookupLadder(for: row.target).map(\.serialized)
        })
        for key in store.entries.keys where !covered.contains(key.serialized) {
            rows.append(IconTargetRow(orphanedKey: key))
        }

        return rows.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Off the main thread, back on it.
    static func load(store: IconStore, completion: @escaping ([IconTargetRow]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let rows = all(store: store)
            DispatchQueue.main.async { completion(rows) }
        }
    }

    // MARK: Private

    private static func applications(in directory: URL, depth: Int,
                                     fileManager: FileManager) -> [URL] {
        guard depth < maximumDepth,
              let contents = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }

        var found: [URL] = []
        for url in contents {
            if url.pathExtension == "app" {
                found.append(url)
                continue
            }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory
            if isDirectory == true {
                found += applications(in: url, depth: depth + 1, fileManager: fileManager)
            }
        }
        return found
    }
}
