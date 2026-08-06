import XCTest
@testable import PictKit

final class IconEntryKeyTests: XCTestCase {

    // MARK: Serialising

    func testRoundTripsThroughItsSerializedForm() {
        let keys: [IconEntryKey] = [
            .app(at: URL(fileURLWithPath: "/Applications/Safari.app")),
            .app(bundleIdentifier: "com.apple.Safari"),
            .file(at: URL(fileURLWithPath: "/Users/someone/Notes.txt")),
            .url(URL(string: "https://example.com/page")!)
        ]
        for key in keys {
            XCTAssertEqual(IconEntryKey(serialized: key.serialized), key, key.serialized)
        }
    }

    func testAValueContainingAColonSurvives() {
        // Only the *first* colon separates the kind, so a URL's own scheme colon
        // must not truncate the value.
        let key = IconEntryKey.url(URL(string: "https://example.com/a:b")!)
        XCTAssertEqual(IconEntryKey(serialized: key.serialized)?.value, "https://example.com/a:b")
    }

    func testRefusesAnUnknownKindOrAnEmptyValue() {
        XCTAssertNil(IconEntryKey(serialized: "sandwich:/Applications/Safari.app"))
        XCTAssertNil(IconEntryKey(serialized: "app:"))
        XCTAssertNil(IconEntryKey(serialized: "no-separator"))
    }

    func testStandardisesPaths() {
        let messy = IconEntryKey.app(at: URL(fileURLWithPath: "/Applications/./Safari.app"))
        let clean = IconEntryKey.app(at: URL(fileURLWithPath: "/Applications/Safari.app"))
        XCTAssertEqual(messy, clean)
    }

    // MARK: The lookup ladder

    /// The whole reason overrides are keyed by path: site-specific-browser wrappers
    /// all report the browser's bundle identifier, so an identifier-first ladder
    /// paints every wrapper with one icon.
    func testPathBeatsBundleIdentifier() {
        let ladder = IconEntryKey.lookupLadder(
            for: .application(bundleURL: URL(fileURLWithPath: "/Applications/Claude.app"),
                              bundleIdentifier: "com.google.Chrome"))
        XCTAssertEqual(ladder.map(\.kind), [.app, .bundleID])
        XCTAssertEqual(ladder.first?.value, "/Applications/Claude.app")
    }

    func testTwoWrappersSharingAnIdentifierGetDifferentKeys() {
        let one = IconEntryKey.storageKey(for: .application(
            bundleURL: URL(fileURLWithPath: "/Applications/Claude.app"),
            bundleIdentifier: "com.google.Chrome"))
        let two = IconEntryKey.storageKey(for: .application(
            bundleURL: URL(fileURLWithPath: "/Applications/CodeNomad.app"),
            bundleIdentifier: "com.google.Chrome"))
        XCTAssertNotEqual(one, two)
        XCTAssertNotEqual(one?.fileStem, two?.fileStem)
    }

    func testAnAppKnownOnlyByIdentifierStillHasAKey() {
        let ladder = IconEntryKey.lookupLadder(
            for: .application(bundleURL: nil, bundleIdentifier: "com.apple.Safari"))
        XCTAssertEqual(ladder, [.app(bundleIdentifier: "com.apple.Safari")])
    }

    func testAnAppWithNeitherNameHasNoStorageKey() {
        XCTAssertNil(IconEntryKey.storageKey(for: .application(bundleURL: nil,
                                                               bundleIdentifier: nil)))
    }

    func testFilesAndLinksHaveNoSecondChance() {
        XCTAssertEqual(IconEntryKey.lookupLadder(for: .file(URL(fileURLWithPath: "/tmp/a"))).count, 1)
        XCTAssertEqual(IconEntryKey.lookupLadder(for: .link(URL(string: "https://a.example")!)).count, 1)
    }

    // MARK: File names

    func testFileStemIsAlwaysASafeName() {
        let hostile: [IconEntryKey] = [
            .app(bundleIdentifier: "../../etc/passwd"),
            .app(bundleIdentifier: "com.apple..Safari"),
            .app(bundleIdentifier: ".hidden"),
            .app(bundleIdentifier: "trailing."),
            .app(bundleIdentifier: "with/slash"),
            .app(bundleIdentifier: "with:colon"),
            .app(bundleIdentifier: String(repeating: "x", count: 500)),
            .url(URL(string: "https://example.com/../../..")!)
        ]
        for key in hostile {
            for ext in ["png", "json"] {
                let name = "\(key.fileStem).\(ext)"
                XCTAssertTrue(IconEntryKey.isSafeFileName(name, extensions: [ext]),
                              "unsafe name from \(key.serialized): \(name)")
            }
        }
    }

    func testDifferentKeysNeverShareAFileStem() {
        // These sanitise to the same stem and are told apart only by the digest.
        let one = IconEntryKey.app(bundleIdentifier: "com/apple/Safari")
        let two = IconEntryKey.app(bundleIdentifier: "com:apple:Safari")
        XCTAssertNotEqual(one.fileStem, two.fileStem)
    }

    func testTheSameKindAndValueUnderDifferentKindsDoNotCollide() {
        let asApp = IconEntryKey(kind: .app, value: "/Applications/Safari.app")
        let asFile = IconEntryKey(kind: .file, value: "/Applications/Safari.app")
        XCTAssertNotEqual(asApp.fileStem, asFile.fileStem)
    }

    func testFileStemIsStableAcrossRuns() {
        // Not `hashValue`, which Swift seeds per process — three separate apps have
        // to name one target's files identically.
        let key = IconEntryKey.app(bundleIdentifier: "com.apple.Safari")
        XCTAssertEqual(key.fileStem, key.fileStem)
        XCTAssertEqual(IconEntryKey.shortDigest(of: "com.apple.Safari"),
                       IconEntryKey.shortDigest(of: "com.apple.Safari"))
    }

    func testFileStemKeepsTheReadablePartOfAPath() {
        let key = IconEntryKey.app(at: URL(fileURLWithPath: "/Applications/Utilities/Terminal.app"))
        XCTAssertTrue(key.fileStem.hasPrefix("Terminal.app-"), key.fileStem)
    }

    // MARK: Path safety

    func testResolvedURLRefusesToEscapeTheDirectory() {
        let directory = URL(fileURLWithPath: "/tmp/pict-entries", isDirectory: true)
        for name in ["../escape.png", "sub/dir.png", "/absolute.png", ".hidden.png", "note.txt"] {
            XCTAssertNil(IconEntryKey.resolvedURL(forFile: name, in: directory,
                                                  extensions: ["png"]), name)
        }
        XCTAssertNotNil(IconEntryKey.resolvedURL(forFile: "fine.png", in: directory,
                                                 extensions: ["png"]))
    }

    func testResolvedURLIsExtensionScoped() {
        let directory = URL(fileURLWithPath: "/tmp/pict-entries", isDirectory: true)
        XCTAssertNil(IconEntryKey.resolvedURL(forFile: "a.json", in: directory, extensions: ["png"]))
        XCTAssertNotNil(IconEntryKey.resolvedURL(forFile: "a.json", in: directory, extensions: ["json"]))
    }
}
