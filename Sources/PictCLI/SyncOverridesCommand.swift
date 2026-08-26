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
            runWatch(store: store, sync: sync)   // never returns
        }
        #else
        throw RuntimeError("sync-overrides applies freedesktop .desktop overrides and is available on Linux only.")
        #endif
    }

    #if os(Linux)
    /// Re-syncs whenever the store or a system applications directory changes, then blocks
    /// forever running the main queue the watchers deliver on. The store watch picks up
    /// `pict set`/`remove`; the system-dir watches pick up an app being installed or
    /// updated (so the override is regenerated from the new system entry). The override
    /// directory itself is deliberately not watched — that would loop on our own writes.
    private func runWatch(store: IconStore, sync: DesktopOverrideSync) -> Never {
        func resync() {
            let s = sync.sync()
            FileHandle.standardError.write(Data(
                "re-synced: \(s.written) written, \(s.removed) removed\n".utf8))
        }

        var watchers: [IconStoreWatcher] = []
        let storeWatcher = IconStoreWatcher(directory: store.entriesDirectory) { resync() }
        storeWatcher.start()
        watchers.append(storeWatcher)

        for directory in Self.systemApplicationDirectories() {
            let watcher = IconStoreWatcher(directory: directory) { resync() }
            watcher.start()
            watchers.append(watcher)
        }

        print("Watching the store and system applications for changes; press Ctrl-C to stop.")
        withExtendedLifetime(watchers) { dispatchMain() }
    }

    /// The system applications directories to watch: each `$XDG_DATA_DIRS/applications`
    /// (defaulting to the spec's `/usr/local/share:/usr/share`).
    private static func systemApplicationDirectories() -> [URL] {
        let raw = ProcessInfo.processInfo.environment["XDG_DATA_DIRS"]
        let dirs = (raw?.isEmpty == false ? raw! : "/usr/local/share:/usr/share")
            .split(separator: ":").map(String.init)
        return dirs.map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("applications", isDirectory: true) }
    }
    #endif
}
