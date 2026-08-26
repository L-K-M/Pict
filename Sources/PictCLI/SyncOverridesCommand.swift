import ArgumentParser
import Foundation
import PictKit

/// `pict sync-overrides` — apply the store to the desktop system-wide by regenerating
/// `~/.local/share/applications/<id>.desktop` shadowing entries (LP-15). Linux only; the
/// override mechanism is a freedesktop one with no macOS counterpart.
struct SyncOverridesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sync-overrides",
        abstract: "Apply the store's icons system-wide via .desktop overrides (Linux).",
        discussion: "Regenerates a shadowing .desktop for every store entry keyed to a "
            + ".desktop file — the current system entry with only Icon= replaced — and "
            + "removes overrides Pict previously wrote that no longer have an entry. "
            + "Files Pict didn't write are never touched."
    )

    @OptionGroup var options: StoreOptions

    @Option(name: .long, help: "The applications directory to write overrides into (default: $XDG_DATA_HOME/applications).")
    var applications: String?

    @Flag(name: .long, help: "Keep running, re-syncing when the store or system entries change.")
    var watch = false

    func run() throws {
        #if os(Linux)
        let store = options.makeStore()
        let overrides = applications.map { URL(fileURLWithPath: (($0 as NSString).expandingTildeInPath),
                                               isDirectory: true) }
        let sync = overrides.map { DesktopOverrideSync(store: store, overridesDirectory: $0) }
            ?? DesktopOverrideSync(store: store)

        let summary = sync.sync()
        print("Synced overrides: \(summary.written) written, \(summary.removed) removed, \(summary.skipped) skipped.")

        if watch {
            // Never watch the directory we write into — that would loop on our own writes —
            // so hand runWatch the resolved overrides dir (the passed one, or the default).
            runWatch(store: store, sync: sync,
                     overridesDirectory: overrides ?? DesktopOverrideSync.defaultOverridesDirectory())   // never returns
        }
        #else
        throw RuntimeError("sync-overrides applies freedesktop .desktop overrides and is available on Linux only.")
        #endif
    }

    #if os(Linux)
    /// Re-syncs whenever the store or an applications directory changes, then blocks forever
    /// running the main queue the watchers deliver on. The store watch picks up `pict
    /// set`/`remove`; the applications-dir watches pick up an app being installed or updated
    /// (so the override is regenerated from the new system entry). The overrides directory is
    /// excluded from the watch set — watching what we write into would loop on our own writes.
    private func runWatch(store: IconStore, sync: DesktopOverrideSync,
                          overridesDirectory: URL) -> Never {
        func resync() {
            let s = sync.sync()
            FileHandle.standardError.write(Data(
                "re-synced: \(s.written) written, \(s.removed) removed\n".utf8))
        }

        var watchers: [IconStoreWatcher] = []
        let storeWatcher = IconStoreWatcher(directory: store.entriesDirectory) { resync() }
        storeWatcher.start()
        watchers.append(storeWatcher)

        for directory in Self.applicationDirectoriesToWatch(
            environment: ProcessInfo.processInfo.environment, excluding: overridesDirectory) {
            let watcher = IconStoreWatcher(directory: directory) { resync() }
            watcher.start()
            watchers.append(watcher)
        }

        // Close the race between `run`'s initial sync and the watchers arming: a change that
        // landed in that window fired no callback, so sync once more now that we're watching.
        resync()

        print("Watching the store and system applications for changes; press Ctrl-C to stop.")
        withExtendedLifetime(watchers) { dispatchMain() }
    }

    /// The applications directories to watch: `$XDG_DATA_HOME/applications` (where user-scope
    /// installs — Flatpak `--user`, `~/.local`-prefixed installs — put their entries) plus
    /// each `$XDG_DATA_DIRS/applications` (defaulting to the spec's `/usr/local/share:/usr/share`),
    /// deduplicated and minus the overrides directory we write into. Pure in its inputs so it
    /// can be unit-tested without touching the process environment.
    static func applicationDirectoriesToWatch(environment: [String: String],
                                              excluding overrides: URL) -> [URL] {
        // Relative $XDG_DATA_HOME/$XDG_DATA_DIRS entries are invalid per the freedesktop
        // base-dir spec and must be ignored; watching one would resolve against an arbitrary cwd.
        let dataHome = environment["XDG_DATA_HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil }
            ?? NSHomeDirectory() + "/.local/share"
        let dataDirs = environment["XDG_DATA_DIRS"].flatMap { $0.isEmpty ? nil : $0 }
            ?? "/usr/local/share:/usr/share"
        let roots = [dataHome] + dataDirs.split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }

        let overridesPath = overrides.standardizedFileURL.path
        var seen = Set<String>()
        var result: [URL] = []
        for root in roots {
            let url = URL(fileURLWithPath: root, isDirectory: true)
                .appendingPathComponent("applications", isDirectory: true)
            let path = url.standardizedFileURL.path
            if path == overridesPath { continue }     // never watch our own write target
            if seen.insert(path).inserted { result.append(url) }
        }
        return result
    }
    #endif
}
