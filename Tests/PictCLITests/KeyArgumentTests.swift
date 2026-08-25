import XCTest
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

    func testURLWithASpaceStaysALinkKeyNotAFileKey() throws {
        // An unparseable-as-given url: value (a raw space) is percent-encoded into a real
        // link key rather than degrading to a bogus file: URL that nothing would match.
        let key = try resolveKey("url:https://example.com/a b.png")
        XCTAssertEqual(key.kind, .url)
        XCTAssertFalse(key.value.hasPrefix("file:"), "must not degrade to a file URL: \(key.value)")
        XCTAssertTrue(key.value.contains("example.com"), key.value)
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

    // MARK: Helper

    private func key(_ argument: String) throws -> IconEntryKey {
        try KeyArgument.key(from: argument).get()
    }
}
