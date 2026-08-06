import CoreGraphics
import XCTest
@testable import PictKit

/// The store's job is to survive three processes writing it. These tests stand two
/// `IconStore`s up over one directory, which is as close as a unit test gets to
/// Zap and Pict running at the same time.
final class IconStoreTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("pict-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Helpers

    private func makeStore() -> IconStore { IconStore(directory: directory) }

    private static let safari = IconTarget.application(
        bundleURL: URL(fileURLWithPath: "/Applications/Safari.app"),
        bundleIdentifier: "com.apple.Safari")

    /// A tiny opaque square — enough to encode, which is all these tests need.
    private func makeImage(side: Int = 128) -> CGImage {
        let context = CGContext(data: nil, width: side, height: side,
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return context.makeImage()!
    }

    // MARK: Round trip

    func testSetsAndReadsBackAnIcon() throws {
        let store = makeStore()
        let result = store.setIcon(makeImage(), for: Self.safari, writtenBy: "Tests")
        guard case .success(let entry) = result else { return XCTFail("\(result)") }

        XCTAssertEqual(entry.origin, .file)
        XCTAssertEqual(entry.writtenBy, "Tests")
        XCTAssertEqual(entry.entryKey, IconEntryKey.app(at: URL(fileURLWithPath: "/Applications/Safari.app")))
        XCTAssertNotNil(store.image(for: Self.safari))
    }

    func testWritesOneJSONAndOnePNGPerEntry() throws {
        let store = makeStore()
        _ = store.setIcon(makeImage(), for: Self.safari)
        let names = try FileManager.default.contentsOfDirectory(atPath: store.entriesDirectory.path)
        XCTAssertEqual(names.filter { $0.hasSuffix(".json") }.count, 1)
        XCTAssertEqual(names.filter { $0.hasSuffix(".png") }.count, 1)
    }

    func testSeedsAReadMeSoTheDirectoryExplainsItself() {
        let store = makeStore()
        _ = store.setIcon(makeImage(), for: Self.safari)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("README.txt").path))
    }

    // MARK: Two processes

    func testAnotherProcessesWriteIsPickedUpOnReload() {
        let mine = makeStore()
        let theirs = makeStore()

        XCTAssertNil(mine.entry(for: Self.safari))
        _ = theirs.setIcon(makeImage(), for: Self.safari, writtenBy: "Pict")

        // Not visible until the watcher reloads — which is the honest model, and why
        // `IconStoreWatcher` exists rather than every read hitting the disk.
        XCTAssertNil(mine.entry(for: Self.safari))
        mine.reload()
        XCTAssertEqual(mine.entry(for: Self.safari)?.writtenBy, "Pict")
    }

    /// Two stores writing two *different* targets is the case that used to lose
    /// entries when everything shared one `manifest.json`.
    func testConcurrentWritesToDifferentTargetsBothSurvive() {
        let zap = makeStore()
        let pict = makeStore()
        let terminal = IconTarget.application(
            bundleURL: URL(fileURLWithPath: "/Applications/Utilities/Terminal.app"),
            bundleIdentifier: "com.apple.Terminal")

        // Both hold a stale view of the other's work, exactly as two processes would.
        _ = zap.setIcon(makeImage(), for: Self.safari, writtenBy: "Zap")
        _ = pict.setIcon(makeImage(), for: terminal, writtenBy: "Pict")

        let fresh = makeStore()
        XCTAssertEqual(fresh.entry(for: Self.safari)?.writtenBy, "Zap")
        XCTAssertEqual(fresh.entry(for: terminal)?.writtenBy, "Pict")
        XCTAssertEqual(fresh.entries.count, 2)
    }

    func testTheSameTargetIsLastWriterWins() {
        let zap = makeStore()
        let pict = makeStore()
        _ = zap.setIcon(makeImage(), for: Self.safari, writtenBy: "Zap")
        _ = pict.setIcon(makeImage(), for: Self.safari, writtenBy: "Pict")

        XCTAssertEqual(makeStore().entry(for: Self.safari)?.writtenBy, "Pict")
    }

    // MARK: The ladder

    func testAPathEntryWinsOverAnIdentifierEntry() {
        let store = makeStore()
        _ = store.pinToSystemIcon(for: .application(bundleURL: nil,
                                                    bundleIdentifier: "com.apple.Safari"))
        _ = store.setIcon(makeImage(), for: Self.safari, writtenBy: "Zap")

        XCTAssertEqual(store.entry(for: Self.safari)?.origin, .file)
    }

    /// Zap hit this moving from identifier keys to path keys: a stale identifier
    /// entry left behind is invisible until the app moves, then the old icon returns.
    func testWritingThePathKeyRetiresTheIdentifierKey() {
        let store = makeStore()
        _ = store.setIcon(makeImage(), for: .application(bundleURL: nil,
                                                         bundleIdentifier: "com.apple.Safari"))
        XCTAssertNotNil(store.entry(for: IconEntryKey.app(bundleIdentifier: "com.apple.Safari")))

        _ = store.setIcon(makeImage(), for: Self.safari)
        XCTAssertNil(store.entry(for: IconEntryKey.app(bundleIdentifier: "com.apple.Safari")))
    }

    func testClearingRemovesEveryKeyTheTargetCouldBeUnder() {
        let store = makeStore()
        _ = store.setIcon(makeImage(), for: .application(bundleURL: nil,
                                                         bundleIdentifier: "com.apple.Safari"))
        _ = store.adopt(IconEntry(key: IconEntryKey.app(at: URL(fileURLWithPath: "/Applications/Safari.app")).serialized,
                                  source: IconEntry.Origin.system.rawValue),
                        for: IconEntryKey.app(at: URL(fileURLWithPath: "/Applications/Safari.app")))

        store.clear(for: Self.safari)
        XCTAssertNil(store.entry(for: Self.safari))
        XCTAssertTrue(store.entries.isEmpty)
    }

    // MARK: Pins

    func testAPinNamesNoImageAndStopsSubstitution() {
        let store = makeStore()
        _ = store.setIcon(makeImage(), for: Self.safari)
        XCTAssertTrue(store.pinToSystemIcon(for: Self.safari))

        XCTAssertTrue(store.isPinnedToSystemIcon(Self.safari))
        XCTAssertNil(store.imageURL(for: Self.safari))
        // The PNG the override used is gone, not orphaned.
        let names = try? FileManager.default.contentsOfDirectory(atPath: store.entriesDirectory.path)
        XCTAssertEqual(names?.filter { $0.hasSuffix(".png") }.count, 0)
    }

    // MARK: Robustness

    /// The state a half-finished delete leaves. It must read as "no override", not
    /// as a broken store.
    func testAnEntryWhoseImageIsMissingIsIgnored() throws {
        let store = makeStore()
        _ = store.setIcon(makeImage(), for: Self.safari)
        let png = try XCTUnwrap(store.imageURL(for: Self.safari))
        try FileManager.default.removeItem(at: png)

        XCTAssertNil(makeStore().entry(for: Self.safari))
    }

    func testOneUnreadableEntryDoesNotCostTheOthers() throws {
        let store = makeStore()
        _ = store.setIcon(makeImage(), for: Self.safari)
        try Data("{ not json".utf8).write(
            to: store.entriesDirectory.appendingPathComponent("broken.json"))

        XCTAssertEqual(makeStore().entries.count, 1)
    }

    func testAnEntryNamingAFileOutsideTheDirectoryIsDropped() throws {
        let store = makeStore()
        _ = store.setIcon(makeImage(), for: Self.safari)
        let hostile = """
            { "key": "app:/Applications/Evil.app", "image": "../../../etc/passwd",
              "source": "file", "version": 1 }
            """
        try Data(hostile.utf8).write(
            to: store.entriesDirectory.appendingPathComponent("hostile.json"))

        let fresh = makeStore()
        XCTAssertEqual(fresh.entries.count, 1)
        XCTAssertNil(fresh.entry(for: IconEntryKey(kind: .app, value: "/Applications/Evil.app")))
    }

    func testAnEmptyDirectoryIsAnEmptyStoreRatherThanAFailure() {
        XCTAssertTrue(IconStore(directory: directory.appendingPathComponent("nope")).entries.isEmpty)
    }

    /// Three independently released readers means an old build will meet a new
    /// build's entries. It must leave them alone rather than rewriting them lossily.
    func testWillNotRewriteAnEntryFromANewerBuild() {
        let store = makeStore()
        let key = IconEntryKey.app(bundleIdentifier: "com.apple.Safari")
        let future = IconEntry(version: IconEntry.currentVersion + 1, key: key.serialized,
                               source: IconEntry.Origin.system.rawValue, writtenBy: "Pict 9")
        XCTAssertTrue(store.adopt(future, for: key))

        let older = IconEntry(key: key.serialized, source: IconEntry.Origin.system.rawValue,
                              writtenBy: "Zap 1")
        XCTAssertFalse(store.adopt(older, for: key))
        XCTAssertEqual(store.entry(for: key)?.writtenBy, "Pict 9")
    }

    func testAUserActionStillWinsOverANewerBuildsEntry() {
        let store = makeStore()
        let key = IconEntryKey.app(bundleIdentifier: "com.apple.Safari")
        _ = store.adopt(IconEntry(version: IconEntry.currentVersion + 1, key: key.serialized,
                                  source: IconEntry.Origin.system.rawValue), for: key)

        // `setIcon` replaces rather than edits, so there is nothing to lose.
        let result = store.setIcon(makeImage(),
                                   for: .application(bundleURL: nil,
                                                     bundleIdentifier: "com.apple.Safari"),
                                   writtenBy: "Zap")
        guard case .success = result else { return XCTFail("\(result)") }
        XCTAssertEqual(store.entry(for: key)?.writtenBy, "Zap")
    }

    func testATargetWithNoKeyCannotBeWritten() {
        let store = makeStore()
        let result = store.setIcon(makeImage(),
                                   for: .application(bundleURL: nil, bundleIdentifier: nil))
        guard case .failure(.unkeyable) = result else { return XCTFail("\(result)") }
    }

    func testRemoveAllLeavesNothingBehind() throws {
        let store = makeStore()
        _ = store.setIcon(makeImage(), for: Self.safari)
        _ = store.setIcon(makeImage(), for: .file(URL(fileURLWithPath: "/tmp/a.txt")))
        store.removeAll()

        XCTAssertTrue(store.entries.isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: store.entriesDirectory.path)
        XCTAssertTrue(names.filter { $0.hasSuffix(".png") || $0.hasSuffix(".json") }.isEmpty)
    }
}
