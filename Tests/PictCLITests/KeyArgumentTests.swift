import XCTest
import Foundation
import PictKit
@testable import pict_cli

/// Unit tests for the CLI's argument→action mapping: turning a key string into an
/// `IconEntryKey`, and mapping that key back to the `IconTarget` `set` stores under.
final class KeyArgumentTests: XCTestCase {

    // MARK: Serialized forms

    func testSerializedFormsParseVerbatim() {
        XCTAssertEqual(try key("app:/Applications/Safari.app"),
                       IconEntryKey(kind: .app, value: "/Applications/Safari.app"))
        XCTAssertEqual(try key("bundleID:com.apple.Safari"),
                       IconEntryKey(kind: .bundleID, value: "com.apple.Safari"))
        XCTAssertEqual(try key("file:/Users/me/notes.txt"),
                       IconEntryKey(kind: .file, value: "/Users/me/notes.txt"))
        XCTAssertEqual(try key("url:https://example.com/"),
                       IconEntryKey(kind: .url, value: "https://example.com/"))
    }

    func testSerializedFormsRoundTripThroughList() {
        // The string `pict list` prints is `serialized`; feeding it back must reproduce
        // the same key, so a key copied from `list` works in `get`/`set`/`remove`.
        for original in [IconEntryKey(kind: .app, value: "/Applications/Safari.app"),
                         IconEntryKey(kind: .bundleID, value: "com.apple.Safari"),
                         IconEntryKey(kind: .file, value: "/tmp/a b.txt"),
                         IconEntryKey(kind: .url, value: "https://example.com/x")] {
            XCTAssertEqual(try key(original.serialized), original)
        }
    }

    // MARK: Bare .desktop paths

    func testBareDesktopPathIsStoredUnderAppKind() {
        XCTAssertEqual(try key("/usr/share/applications/firefox.desktop"),
                       IconEntryKey(kind: .app, value: "/usr/share/applications/firefox.desktop"))
        XCTAssertEqual(try key("firefox.desktop"),
                       IconEntryKey(kind: .app, value: "firefox.desktop"))
        // Case-insensitive suffix.
        XCTAssertEqual(try key("App.DESKTOP"), IconEntryKey(kind: .app, value: "App.DESKTOP"))
    }

    func testKindPrefixWinsOverDesktopHeuristic() {
        // A bundle identifier that happens to end in `.desktop` stays a bundleID, because
        // the serialized `kind:` form is recognized before the `.desktop` fallback.
        XCTAssertEqual(try key("bundleID:com.foo.desktop"),
                       IconEntryKey(kind: .bundleID, value: "com.foo.desktop"))
    }

    // MARK: Failures

    func testEmptyIsRejected() {
        XCTAssertEqual(KeyArgument.key(from: "   "), .failure(.empty))
        XCTAssertEqual(KeyArgument.key(from: ""), .failure(.empty))
    }

    func testUnrecognizedIsRejected() {
        XCTAssertEqual(KeyArgument.key(from: "just-a-string"), .failure(.unrecognized("just-a-string")))
        // An unknown kind with a colon isn't a valid serialized key and isn't a .desktop
        // path, so it's unrecognized rather than silently coerced.
        XCTAssertEqual(KeyArgument.key(from: "widget:/x"), .failure(.unrecognized("widget:/x")))
    }

    func testKnownKindWithEmptyValueIsRejected() {
        // A known kind with an empty value (`app:`) must not slip through as a zero-length
        // path/URL. IconEntryKey(serialized:) rejects the empty value, and `app:` isn't a
        // .desktop path, so it lands as unrecognized rather than a bogus empty key.
        XCTAssertEqual(KeyArgument.key(from: "app:"), .failure(.unrecognized("app:")))
        XCTAssertEqual(KeyArgument.key(from: "file:"), .failure(.unrecognized("file:")))
        XCTAssertEqual(KeyArgument.key(from: "url:"), .failure(.unrecognized("url:")))
    }

    func testSchemePrefixedDesktopStringsAreNotAppPaths() {
        // Anything with a URI scheme at the start ending in `.desktop` is a link, not a
        // desktop-entry path, and must not be coerced into a bogus `app:` key — including
        // spellings a plain `://` check misses (single slash, no slashes at all).
        for argument in ["https://example.com/apps/firefox.desktop",
                         "https:/example.com/x.desktop",
                         "data:text/plain,x.desktop"] {
            XCTAssertEqual(KeyArgument.key(from: argument), .failure(.unrecognized(argument)),
                           "\(argument) should not be an app path")
        }
    }

    func testPathWithAMidStringColonStaysAnAppPath() throws {
        // A colon that isn't a scheme prefix (it's inside the path) leaves the `.desktop`
        // path an app: key — the anchored scheme check only rejects `scheme:` at the start.
        XCTAssertEqual(try key("/opt/a:b/x.desktop"),
                       IconEntryKey(kind: .app, value: "/opt/a:b/x.desktop"))
    }

    func testLeadingAndTrailingWhitespaceIsTrimmed() {
        XCTAssertEqual(try key("  app:/A/B.app \n"), IconEntryKey(kind: .app, value: "/A/B.app"))
    }

    // MARK: Key → target

    func testAsTargetMapsEachKind() {
        XCTAssertEqual(IconEntryKey(kind: .app, value: "/A/B.app").asTarget,
                       .application(bundleURL: URL(fileURLWithPath: "/A/B.app"), bundleIdentifier: nil))
        XCTAssertEqual(IconEntryKey(kind: .bundleID, value: "com.foo").asTarget,
                       .application(bundleURL: nil, bundleIdentifier: "com.foo"))
        XCTAssertEqual(IconEntryKey(kind: .file, value: "/tmp/x").asTarget,
                       .file(URL(fileURLWithPath: "/tmp/x")))
        XCTAssertEqual(IconEntryKey(kind: .url, value: "https://example.com/").asTarget,
                       .link(URL(string: "https://example.com/")!))
    }

    func testAppKeyRoundTripsThroughItsTarget() {
        // A `set` under an `app:` key derives a target whose own storage key is that key
        // again (the path is already standardized), so the entry lands where `get` and
        // `remove` will look for it.
        let original = IconEntryKey(kind: .app, value: "/Applications/Safari.app")
        XCTAssertEqual(IconEntryKey.storageKey(for: original.asTarget), original)
    }

    func testURLRepairKeepsALinkKeyAndPreservesFragments() throws {
        // An unparseable-as-given url: value (a raw space) becomes a real link key, not a
        // bogus file: URL that nothing would match.
        let spaced = try resolveKey("url:https://example.com/a b.png")
        XCTAssertEqual(spaced.kind, .url)
        XCTAssertFalse(spaced.value.hasPrefix("file:"), "must not degrade to a file URL: \(spaced.value)")
        XCTAssertTrue(spaced.value.contains("example.com"), spaced.value)

        // A fragment on a space-bearing URL stays a fragment (`#sec`) rather than being
        // folded into the path as `%23`.
        let fragment = try resolveKey("url:https://example.com/my page#sec")
        XCTAssertEqual(fragment.kind, .url)
        XCTAssertTrue(fragment.value.contains("#sec"), "fragment lost: \(fragment.value)")
        XCTAssertFalse(fragment.value.contains("%23"), "fragment delimiter was encoded: \(fragment.value)")
    }

    func testLeadingTildeInPathKeysIsExpanded() throws {
        // A quoted `~/…` the shell left intact expands to the home directory, so the key
        // matches the app's real absolute path, not a cwd-relative `~` path.
        let home = NSHomeDirectory()
        XCTAssertEqual(try resolveKey("~/Applications/Foo.desktop"),   // bare .desktop → app: kind
                       IconEntryKey(kind: .app, value: "\(home)/Applications/Foo.desktop"))
        XCTAssertEqual(try resolveKey("file:~/notes.txt"),
                       IconEntryKey(kind: .file, value: "\(home)/notes.txt"))
    }

    func testResolvedKeysAreCanonical() throws {
        // Whatever the user types, `resolveKey` must land on the same key `IconStore`
        // derives — so `set`, `get` and `remove` always agree. This is the invariant that
        // keeps a relative `.desktop` path (or any non-canonical path/URL) reachable after
        // `set` standardizes it. `storageKey(for: key.asTarget) == key` is exactly that
        // fixed point.
        for argument in ["/usr/share/applications/firefox.desktop", "firefox.desktop",
                         "file:/tmp/x/../x", "url:https://example.com", "app:/A/B.app",
                         "bundleID:com.foo"] {
            let key = try resolveKey(argument)
            XCTAssertEqual(IconEntryKey.storageKey(for: key.asTarget), key,
                           "resolveKey(\(argument)) is not a storageKey fixed point")
        }
    }

    // MARK: sync-overrides watch directories (Linux)

    #if os(Linux)
    func testWatchDirsIncludeXDGDataHomeDedupeAndExcludeTheOverridesDir() {
        let env = ["XDG_DATA_HOME": "/home/u/.local/share",
                   "XDG_DATA_DIRS": "/usr/share:/usr/share:relative/dir"]   // dup + one relative
        let overrides = URL(fileURLWithPath: "/custom/apps", isDirectory: true)
        let dirs = SyncOverridesCommand
            .applicationDirectoriesToWatch(environment: env, excluding: overrides)
            .map(\.standardizedFileURL.path)

        XCTAssertTrue(dirs.contains("/home/u/.local/share/applications"),
                      "XDG_DATA_HOME/applications is watched for user-scope installs")
        XCTAssertEqual(dirs.filter { $0 == "/usr/share/applications" }.count, 1,
                       "duplicate XDG_DATA_DIRS entries collapse to one watcher")
        // "relative/dir" would join to "relative/dir/applications" if it weren't filtered.
        XCTAssertFalse(dirs.contains("relative/dir/applications"), "relative entries are ignored")
        XCTAssertTrue(dirs.allSatisfy { $0.hasPrefix("/") }, "every watched dir is absolute")
    }

    func testWatchDirsExcludeAnOverridesDirReachedViaASymlink() throws {
        // A --applications passed as a symlinked alias of a real applications dir must still
        // be excluded — resolvingSymlinksInPath canonicalizes both sides of the comparison.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pict-watch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let realShare = root.appendingPathComponent("share", isDirectory: true)
        let realApps = realShare.appendingPathComponent("applications", isDirectory: true)
        try FileManager.default.createDirectory(at: realApps, withIntermediateDirectories: true)
        let aliasShare = root.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: aliasShare, withDestinationURL: realShare)

        let env = ["XDG_DATA_HOME": realShare.path, "XDG_DATA_DIRS": "/usr/share"]
        let dirs = SyncOverridesCommand.applicationDirectoriesToWatch(
            environment: env,
            excluding: aliasShare.appendingPathComponent("applications", isDirectory: true))
            .map { $0.resolvingSymlinksInPath().path }
        XCTAssertFalse(dirs.contains(realApps.resolvingSymlinksInPath().path),
                       "the write target reached via a symlink is still excluded")
        XCTAssertTrue(dirs.contains("/usr/share/applications"))
    }

    func testWatchDirsExcludeTheOverridesDirEvenWhenItIsXDGDataHome() {
        // The default overrides dir IS $XDG_DATA_HOME/applications — watching it would loop
        // on our own writes, so it must be dropped from the watch set.
        let env = ["XDG_DATA_HOME": "/home/u/.local/share", "XDG_DATA_DIRS": "/usr/share"]
        let overrides = URL(fileURLWithPath: "/home/u/.local/share/applications", isDirectory: true)
        let dirs = SyncOverridesCommand
            .applicationDirectoriesToWatch(environment: env, excluding: overrides)
            .map(\.standardizedFileURL.path)

        XCTAssertFalse(dirs.contains("/home/u/.local/share/applications"),
                       "the directory we write into is never watched")
        XCTAssertTrue(dirs.contains("/usr/share/applications"))
    }
    #endif

    // MARK: Helper

    private func key(_ argument: String) throws -> IconEntryKey {
        try KeyArgument.key(from: argument).get()
    }
}
