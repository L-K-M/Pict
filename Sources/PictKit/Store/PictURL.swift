#if canImport(AppKit)
import AppKit
#endif
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
    ///
    /// **On Linux this returns the handler's `.desktop` file when it can be located, or
    /// `nil` otherwise — always a real file URL, never a marker.** For a pure "is Pict
    /// installed" check that doesn't depend on locating the file, use `isInstalled`
    /// (Linux-only; on macOS compare `installedAppURL()` against `nil`). The first Linux
    /// call blocks (spawns xdg-mime) and, while no handler is registered, re-probes at
    /// most once per 30s — so call it off the main thread.
    public static func installedAppURL() -> URL? {
        #if canImport(AppKit)
        guard let probe else { return nil }
        return NSWorkspace.shared.urlForApplication(toOpen: probe)
        #else
        guard let handler = registeredSchemeHandler(), !handler.isEmpty else { return nil }
        return desktopEntryURL(named: handler)
        #endif
    }

    #if !canImport(AppKit)
    /// Whether a default handler for Pict's scheme is registered — the Linux presence
    /// check, split from the location `installedAppURL()` returns so callers never see a
    /// fabricated marker URL. Blocks on first use (spawns xdg-mime) and, while no handler
    /// is registered, re-probes at most once per 30s; call off the main thread.
    public static var isInstalled: Bool { registeredSchemeHandler()?.isEmpty == false }
    #endif

    /// Where to send someone who hasn't got it.
    public static var homepage: URL? { URL(string: "https://github.com/L-K-M/Pict") }

    /// Opens Pict at `target`, or just opens Pict when there is nothing to select.
    /// Returns whether anything was opened.
    ///
    /// **On Linux the first call blocks briefly** — the `xdg-mime` spawn behind
    /// `registeredSchemeHandler()`, repeated at most once per 30s while Pict isn't the
    /// registered handler — so if this is reachable from UI code, call or pre-warm it off
    /// the main thread.
    @discardableResult
    public static func open(selecting target: IconTarget?) -> Bool {
        guard let url = target.flatMap(edit) ?? probe else { return false }
        #if canImport(AppKit)
        return NSWorkspace.shared.open(url)
        #else
        // `xdg-open` spawns happily even when no handler is registered for the scheme
        // (it then exits non-zero), so its launch can't stand in for "opened" the way
        // NSWorkspace.open does. Gate on a registered scheme handler (the Bool's real
        // contract), rather than on installedAppURL() which also locates the .desktop
        // file — a separate, slower concern.
        guard let handler = registeredSchemeHandler(), !handler.isEmpty else { return false }
        return launch("xdg-open", [url.absoluteString])
        #endif
    }

    #if !canImport(AppKit)
    // MARK: Linux (XDG)

    private static let handlerLock = NSLock()
    private static var cachedSchemeHandler: String?
    private static var lastNegativeProbe: Date?
    /// How long a "no handler registered" result is trusted before `xdg-mime` is spawned
    /// again. Bounds the spawn rate while Pict isn't installed, yet still notices an
    /// install within a few seconds.
    private static let negativeProbeTTL: TimeInterval = 30

    /// The XDG default handler for Pict's scheme. `xdg-mime` is a shell script (it may
    /// chain gio/xprop), so a per-call spawn is too heavy for what was a free Launch
    /// Services lookup on macOS — but a *negative* result must not be frozen (Launch
    /// Services is dynamic; a user can install Pict, or make it the default, mid-run).
    /// So a registered handler is cached forever, and a nil/empty probe is trusted only
    /// for `negativeProbeTTL` before it is re-run: bounded spawns, but an install is
    /// still picked up within seconds.
    private static func registeredSchemeHandler() -> String? {
        handlerLock.lock()
        defer { handlerLock.unlock() }
        if let cached = cachedSchemeHandler, !cached.isEmpty { return cached }
        if let probed = lastNegativeProbe, Date().timeIntervalSince(probed) < negativeProbeTTL { return nil }
        lastNegativeProbe = Date()
        cachedSchemeHandler = capture("xdg-mime", ["query", "default", "x-scheme-handler/\(scheme)"])
        return cachedSchemeHandler
    }

    /// `/usr/bin/env` resolves a command via `PATH`, but the path isn't universal
    /// (NixOS, minimal containers); fall back to `/bin/env`.
    private static let envURL = URL(fileURLWithPath:
        ["/usr/bin/env", "/bin/env"].first { FileManager.default.fileExists(atPath: $0) } ?? "/usr/bin/env")

    /// The `.desktop` file for a handler name, searched across the XDG application
    /// directories, or `nil` if it isn't found there.
    private static func desktopEntryURL(named handler: String) -> URL? {
        let leaf = (handler as NSString).lastPathComponent
        guard !leaf.isEmpty else { return nil }
        // The user applications dir is `$XDG_DATA_HOME/applications`, defaulting to
        // ~/.local/share/applications; then the system `$XDG_DATA_DIRS`. The XDG spec
        // requires these absolute — a set-but-relative (or empty) value is ignored, as
        // GLib does — so `hasPrefix("/")` gates both, avoiding CWD-relative probes.
        let dataHome = ProcessInfo.processInfo.environment["XDG_DATA_HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/share", isDirectory: true).path
        var roots = [URL(fileURLWithPath: dataHome, isDirectory: true)
            .appendingPathComponent("applications", isDirectory: true)]
        // Set-but-empty means unset here too (XDG spec / GLib).
        let dataDirs = ProcessInfo.processInfo.environment["XDG_DATA_DIRS"].flatMap { $0.isEmpty ? nil : $0 }
            ?? "/usr/local/share:/usr/share"
        for dir in dataDirs.split(separator: ":") where dir.hasPrefix("/") {
            roots.append(URL(fileURLWithPath: String(dir), isDirectory: true)
                .appendingPathComponent("applications", isDirectory: true))
        }
        for root in roots {
            // A desktop-file ID encodes each `applications/` subdirectory as `-`
            // (`foo-bar.desktop` → `applications/foo/bar.desktop`), so try the
            // dash-to-slash translation as well as the literal leaf.
            for relative in [leaf.replacingOccurrences(of: "-", with: "/"), leaf] {
                let candidate = root.appendingPathComponent(relative)
                if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            }
        }
        return nil
    }

    /// Runs `command arguments` (resolved via `PATH`), returning its trimmed stdout,
    /// or `nil` if it couldn't be launched or exited non-zero.
    private static func capture(_ command: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = envURL
        process.arguments = [command] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Launches `command arguments` (resolved via `PATH`), returning whether it
    /// started — the fire-and-forget contract `open(selecting:)` promises.
    private static func launch(_ command: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = envURL
        process.arguments = [command] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        // Fire-and-forget: a termination handler makes Foundation reap the child
        // asynchronously so it doesn't linger as a zombie (don't also call
        // waitUntilExit). Set before run() so a fast exit can't be missed.
        process.terminationHandler = { _ in }
        return (try? process.run()) != nil
    }
    #endif

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
