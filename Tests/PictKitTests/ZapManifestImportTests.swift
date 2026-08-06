import XCTest
@testable import PictKit

final class ZapManifestImportTests: XCTestCase {

    private var root: URL!
    private var legacy: URL!
    private var storeDirectory: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("pict-migrate-\(UUID().uuidString)", isDirectory: true)
        legacy = root.appendingPathComponent("Zap/Icons", isDirectory: true)
        storeDirectory = root.appendingPathComponent("Pict", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Helpers

    private func writeLegacy(_ json: String, pngs: [String] = []) throws {
        try Data(json.utf8).write(to: legacy.appendingPathComponent("manifest.json"))
        for png in pngs {
            try Data([0x89, 0x50, 0x4E, 0x47]).write(to: legacy.appendingPathComponent(png))
        }
    }

    private func makeStore() -> IconStore { IconStore(directory: storeDirectory) }

    // MARK: Key mapping

    /// Zap told a path from an identifier by a leading slash, and both had to keep
    /// working — that is what let it change keys without migrating anything.
    func testMapsLegacyKeysOntoTheRightKind() {
        XCTAssertEqual(ZapManifestImport.key(forLegacyKey: "/Applications/Safari.app")?.kind, .app)
        XCTAssertEqual(ZapManifestImport.key(forLegacyKey: "com.apple.Safari")?.kind, .bundleID)
        XCTAssertNil(ZapManifestImport.key(forLegacyKey: ""))
    }

    // MARK: Importing

    func testImportsAFileEntryWithItsAttribution() throws {
        try writeLegacy("""
            { "version": 1, "entries": { "/Applications/Safari.app": {
                "file": "com.apple.Safari.png", "source": "search",
                "provider": "iconify", "credit": "Someone",
                "creditURL": "https://example.com", "license": "MIT" } } }
            """, pngs: ["com.apple.Safari.png"])

        let store = makeStore()
        let outcome = ZapManifestImport.run(into: store, from: legacy)

        XCTAssertEqual(outcome.imported, 1)
        XCTAssertEqual(outcome.skipped, 0)

        let target = IconTarget.application(
            bundleURL: URL(fileURLWithPath: "/Applications/Safari.app"),
            bundleIdentifier: "com.apple.Safari")
        let entry = try XCTUnwrap(store.entry(for: target))
        XCTAssertEqual(entry.origin, .search)
        XCTAssertEqual(entry.credit, "Someone")
        XCTAssertEqual(entry.license, "MIT")
        XCTAssertEqual(entry.writtenBy, "Zap (migrated)")
        XCTAssertNotNil(store.imageURL(for: target))
    }

    func testImportsASystemPinWhichNamesNoImage() throws {
        try writeLegacy("""
            { "version": 1, "entries": { "com.apple.Notes": { "source": "system" } } }
            """)

        let store = makeStore()
        XCTAssertEqual(ZapManifestImport.run(into: store, from: legacy).imported, 1)

        let target = IconTarget.application(bundleURL: nil, bundleIdentifier: "com.apple.Notes")
        XCTAssertTrue(store.isPinnedToSystemIcon(target))
        XCTAssertNil(store.imageURL(for: target))
    }

    func testSkipsAnEntryWhosePNGIsMissing() throws {
        try writeLegacy("""
            { "version": 1, "entries": { "com.apple.Safari": {
                "file": "gone.png", "source": "file" } } }
            """)

        let outcome = ZapManifestImport.run(into: makeStore(), from: legacy)
        XCTAssertEqual(outcome.imported, 0)
        XCTAssertEqual(outcome.skipped, 1)
    }

    func testSkipsAnEntryNamingAFileOutsideTheLegacyDirectory() throws {
        try writeLegacy("""
            { "version": 1, "entries": { "com.apple.Safari": {
                "file": "../../../etc/passwd", "source": "file" } } }
            """)

        XCTAssertEqual(ZapManifestImport.run(into: makeStore(), from: legacy).imported, 0)
    }

    /// The shared store is the newer decision by construction — the user cannot have
    /// written it before the migration that created it.
    func testDoesNotClobberAnIconAlreadyInTheSharedStore() throws {
        try writeLegacy("""
            { "version": 1, "entries": { "com.apple.Safari": {
                "file": "a.png", "source": "file" } } }
            """, pngs: ["a.png"])

        let store = makeStore()
        let key = IconEntryKey.app(bundleIdentifier: "com.apple.Safari")
        XCTAssertTrue(store.adopt(IconEntry(key: key.serialized,
                                            source: IconEntry.Origin.system.rawValue,
                                            writtenBy: "Pict"), for: key))

        let outcome = ZapManifestImport.run(into: store, from: legacy)
        XCTAssertEqual(outcome.imported, 0)
        XCTAssertEqual(outcome.skipped, 1)
        XCTAssertEqual(store.entry(for: key)?.writtenBy, "Pict")
    }

    // MARK: Running once

    func testArchivesTheOldDirectorySoASecondRunDoesNothing() throws {
        try writeLegacy("""
            { "version": 1, "entries": { "com.apple.Safari": { "source": "system" } } }
            """)

        let store = makeStore()
        let first = ZapManifestImport.run(into: store, from: legacy)
        XCTAssertEqual(first.imported, 1)
        let archived = try XCTUnwrap(first.archivedAt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archived.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))

        XCTAssertEqual(ZapManifestImport.run(into: store, from: legacy), .nothingToDo)
    }

    func testNoManifestIsNotAnError() {
        let empty = root.appendingPathComponent("nowhere", isDirectory: true)
        XCTAssertEqual(ZapManifestImport.run(into: makeStore(), from: empty), .nothingToDo)
    }

    func testAnUnparseableManifestIsLeftAloneRatherThanArchived() throws {
        try writeLegacy("{ this is not json")
        XCTAssertEqual(ZapManifestImport.run(into: makeStore(), from: legacy), .nothingToDo)
        // Left in place: archiving it would hide the only copy of the user's icons.
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
    }
}
