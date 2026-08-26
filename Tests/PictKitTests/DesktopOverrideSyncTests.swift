#if os(Linux)
import XCTest
@testable import PictKit

final class DesktopOverrideSyncTests: XCTestCase {

    private var root: URL!
    private var storeDir: URL!
    private var overridesDir: URL!
    private var systemDesktop: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pict-overrides-\(UUID().uuidString)", isDirectory: true)
        storeDir = root.appendingPathComponent("Pict", isDirectory: true)
        overridesDir = root.appendingPathComponent("applications", isDirectory: true)
        // A fake system entry under an `applications/` dir, so the id rule is exercised.
        let systemApps = root.appendingPathComponent("usr/share/applications", isDirectory: true)
        try FileManager.default.createDirectory(at: systemApps, withIntermediateDirectories: true)
        systemDesktop = systemApps.appendingPathComponent("firefox.desktop")
        try "[Desktop Entry]\nName=Firefox\nExec=firefox %u\nIcon=firefox\n"
            .write(to: systemDesktop, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    /// A store holding one entry keyed to the fake system `.desktop`.
    private func makeStoreWithFirefoxEntry() throws -> (IconStore, IconTarget) {
        let store = IconStore(directory: storeDir)
        let target = IconTarget.application(bundleURL: systemDesktop, bundleIdentifier: nil)
        var samples = [UInt8]()
        for _ in 0..<(64 * 64) { samples += [0, 0, 200, 255] }   // opaque blue, premultiplied
        let image = try XCTUnwrap(PixelImage(width: 64, height: 64, samples: samples))
        guard case .success = store.setIcon(image, for: target) else {
            throw XCTSkip("store write failed")
        }
        return (store, target)
    }

    private var override: URL { overridesDir.appendingPathComponent("firefox.desktop") }

    func testSyncGeneratesAnOverrideThatReplacesOnlyTheIcon() throws {
        let (store, _) = try makeStoreWithFirefoxEntry()
        let summary = DesktopOverrideSync(store: store, overridesDirectory: overridesDir).sync()

        XCTAssertEqual(summary.written, 1)
        XCTAssertEqual(summary.removed, 0)
        let content = try String(contentsOf: override, encoding: .utf8)
        XCTAssertTrue(content.contains("Name=Firefox"), content)         // preserved
        XCTAssertTrue(content.contains("Exec=firefox %u"), content)      // preserved
        XCTAssertTrue(content.contains("X-Pict-Managed=true"), content)  // marked
        XCTAssertFalse(content.contains("Icon=firefox\n"), content)      // old icon gone
        XCTAssertTrue(content.contains("Icon=\(store.entriesDirectory.standardizedFileURL.path)"), content)
        XCTAssertTrue(content.contains(".png"), content)
    }

    func testResyncIsANoOpWhenNothingChanged() throws {
        let (store, _) = try makeStoreWithFirefoxEntry()
        let sync = DesktopOverrideSync(store: store, overridesDirectory: overridesDir)
        XCTAssertEqual(sync.sync().written, 1)
        XCTAssertEqual(sync.sync().written, 0, "an unchanged override is not rewritten")
    }

    func testRemovingTheEntryRemovesTheOverride() throws {
        let (store, target) = try makeStoreWithFirefoxEntry()
        let sync = DesktopOverrideSync(store: store, overridesDirectory: overridesDir)
        _ = sync.sync()
        XCTAssertTrue(FileManager.default.fileExists(atPath: override.path))

        store.clear(for: target)
        let summary = sync.sync()
        XCTAssertEqual(summary.removed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: override.path),
                       "the stale, Pict-managed override is reaped")
    }

    func testNeverTouchesAFileItDidNotWrite() throws {
        let (store, target) = try makeStoreWithFirefoxEntry()
        try FileManager.default.createDirectory(at: overridesDir, withIntermediateDirectories: true)
        let hand = overridesDir.appendingPathComponent("hand-authored.desktop")
        let handContent = "[Desktop Entry]\nName=Hand\nIcon=hand\n"
        try handContent.write(to: hand, atomically: true, encoding: .utf8)

        let sync = DesktopOverrideSync(store: store, overridesDirectory: overridesDir)
        _ = sync.sync()
        // Even after the entry is gone — so the removal pass runs over the directory — a
        // file without the X-Pict-Managed marker is left exactly as it was.
        store.clear(for: target)
        _ = sync.sync()
        XCTAssertEqual(try String(contentsOf: hand, encoding: .utf8), handContent)
    }

    func testAMissingSystemEntryIsSkipped() throws {
        let (store, _) = try makeStoreWithFirefoxEntry()
        try FileManager.default.removeItem(at: systemDesktop)   // app "uninstalled"
        let summary = DesktopOverrideSync(store: store, overridesDirectory: overridesDir).sync()
        XCTAssertEqual(summary.written, 0)
        XCTAssertEqual(summary.skipped, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: override.path))
    }
}
#endif
