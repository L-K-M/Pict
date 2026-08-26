#if os(Linux)
import XCTest
@testable import PictKit

private struct StoreWriteFailed: Error {}

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
        if let root, FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    /// A store holding one entry keyed to the fake system `.desktop`.
    private func makeStoreWithFirefoxEntry() throws -> (IconStore, IconTarget) {
        let store = IconStore(directory: storeDir)
        let target = IconTarget.application(bundleURL: systemDesktop, bundleIdentifier: nil)
        var samples = [UInt8]()
        for _ in 0..<(64 * 64) { samples += [0, 0, 200, 255] }   // opaque blue, premultiplied
        let image = try XCTUnwrap(PixelImage(width: 64, height: 64, samples: samples))
        guard case .success = store.setIcon(image, for: target) else {
            XCTFail("store write failed")
            throw StoreWriteFailed()
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
        let reap = sync.sync()
        XCTAssertEqual(reap.removed, 1, "our own firefox override is reaped")
        XCTAssertEqual(try String(contentsOf: hand, encoding: .utf8), handContent,
                       "the hand-authored file, distinct id, is untouched")
    }

    func testDoesNotClobberAHandAuthoredFileWithTheSameID() throws {
        // A user's own override already occupies the exact filename our entry resolves to.
        let (store, target) = try makeStoreWithFirefoxEntry()
        try FileManager.default.createDirectory(at: overridesDir, withIntermediateDirectories: true)
        let handContent = "[Desktop Entry]\nName=My Firefox\nIcon=my-firefox\n"
        try handContent.write(to: override, atomically: true, encoding: .utf8)

        let sync = DesktopOverrideSync(store: store, overridesDirectory: overridesDir)
        let summary = sync.sync()
        // We must not write over it (its lack of the marker means it isn't ours), and the
        // refusal surfaces as skipped rather than vanishing into a "0 written, 0 skipped".
        XCTAssertEqual(summary.written, 0)
        XCTAssertEqual(summary.skipped, 1)
        XCTAssertEqual(try String(contentsOf: override, encoding: .utf8), handContent,
                       "an unmarked file at our id is never overwritten")

        // And removing the entry must not reap it either — it was never ours to delete.
        store.clear(for: target)
        _ = sync.sync()
        XCTAssertEqual(try String(contentsOf: override, encoding: .utf8), handContent,
                       "an unmarked file at our id is never reaped")
    }

    func testChangingTheSystemEntryRewritesTheOverride() throws {
        // The override is regenerated from the *current* system entry each sync: when the
        // app updates its .desktop (new Name/Exec), the shadow must pick the change up.
        // (Changing only the store icon does NOT rewrite the override — the PNG filename is
        // key-derived and stable, so the Icon= path is unchanged and the shell reloads the
        // rewritten PNG at that same path; that no-op case is covered by testResyncIsANoOp.)
        let (store, _) = try makeStoreWithFirefoxEntry()
        let sync = DesktopOverrideSync(store: store, overridesDirectory: overridesDir)
        XCTAssertEqual(sync.sync().written, 1)

        try "[Desktop Entry]\nName=Firefox ESR\nExec=firefox-esr %u\nIcon=firefox\n"
            .write(to: systemDesktop, atomically: true, encoding: .utf8)

        XCTAssertEqual(sync.sync().written, 1, "a stale override is regenerated from the new system entry")
        let content = try String(contentsOf: override, encoding: .utf8)
        XCTAssertTrue(content.contains("Name=Firefox ESR"), content)
        XCTAssertTrue(content.contains("Exec=firefox-esr %u"), content)
        XCTAssertTrue(content.contains("X-Pict-Managed=true"), content)
    }

    func testAnUnreadableNonUTF8OverrideIsNeverOverwritten() throws {
        // An existing override that can't be decoded as UTF-8 (a legacy-encoded .desktop)
        // isn't one of ours — `try? String(contentsOf:)` returns nil for it just as for an
        // absent file, and it must be refused, not clobbered.
        let (store, _) = try makeStoreWithFirefoxEntry()
        try FileManager.default.createDirectory(at: overridesDir, withIntermediateDirectories: true)
        // 0xFF 0xFE is not valid UTF-8; write raw bytes to the id our entry resolves to.
        let raw = Data([0xFF, 0xFE, 0x00, 0x41, 0x0A])
        try raw.write(to: override)

        let summary = DesktopOverrideSync(store: store, overridesDirectory: overridesDir).sync()
        XCTAssertEqual(summary.written, 0)
        XCTAssertEqual(summary.skipped, 1)
        XCTAssertEqual(try Data(contentsOf: override), raw, "the undecodable file is left byte-for-byte")
    }

    func testASystemEntryWithoutADesktopEntryGroupIsSkipped() throws {
        // A corrupt/empty system file the rewriter can't mark must not be written unmarked
        // (it could never be reaped) — it's skipped instead.
        try "[Some Other Group]\nIcon=x\n".write(to: systemDesktop, atomically: true, encoding: .utf8)
        let (store, _) = try makeStoreWithFirefoxEntry()
        let summary = DesktopOverrideSync(store: store, overridesDirectory: overridesDir).sync()
        XCTAssertEqual(summary.written, 0)
        XCTAssertEqual(summary.skipped, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: override.path))
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
