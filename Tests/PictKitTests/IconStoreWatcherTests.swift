#if os(Linux)
import Foundation
import XCTest
@testable import PictKit

/// The Linux inotify `IconStoreWatcher`: writes into the watched directory must reach
/// `onChange`, delivered on the main queue like the macOS FSEvents path — and the
/// watcher must survive the directory itself appearing and disappearing.
final class IconStoreWatcherTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("pict-watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testNoticesAFileWrittenIntoTheStore() throws {
        let entries = directory.appendingPathComponent("entries", isDirectory: true)
        try FileManager.default.createDirectory(at: entries, withIntermediateDirectories: true)

        let changes = Counter()
        let watcher = IconStoreWatcher(directory: entries) { changes.bump() }
        watcher.start()
        defer { watcher.stop() }

        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: entries.appendingPathComponent("safari.png"))

        XCTAssertTrue(changes.waitFor(1, timeout: 5),
                      "a file written into the watched store should reach onChange")
    }

    /// The first-run case: the entries directory doesn't exist when watching starts,
    /// so the watcher follows the parent until it appears, then re-arms on it.
    func testFollowsTheParentUntilTheStoreDirectoryAppears() throws {
        let entries = directory.appendingPathComponent("entries", isDirectory: true)
        // Deliberately not created yet — start() must watch the parent.

        let changes = Counter()
        let watcher = IconStoreWatcher(directory: entries) { changes.bump() }
        watcher.start()
        defer { watcher.stop() }

        try FileManager.default.createDirectory(at: entries, withIntermediateDirectories: true)
        try Data([0x89]).write(to: entries.appendingPathComponent("safari.png"))

        XCTAssertTrue(changes.waitFor(1, timeout: 5),
                      "the watcher should notice the store directory being created")
    }

    /// A store reset (`rm -rf` of the entries directory) drops the inotify watch. The
    /// watcher must fall back to the parent and notice the directory being recreated,
    /// rather than going permanently silent.
    func testRecoversWhenTheStoreDirectoryIsDeletedAndRecreated() throws {
        let entries = directory.appendingPathComponent("entries", isDirectory: true)
        try FileManager.default.createDirectory(at: entries, withIntermediateDirectories: true)

        let changes = Counter()
        let watcher = IconStoreWatcher(directory: entries) { changes.bump() }
        watcher.start()
        defer { watcher.stop() }

        // Delete the store; the deletion itself notifies, and (crucially) the watcher
        // re-arms on the parent before that notification fires.
        try FileManager.default.removeItem(at: entries)
        XCTAssertTrue(changes.waitFor(1, timeout: 5), "the store vanishing should notify")

        // Recreate and write into it: without the re-arm the watch is dead and this is
        // never seen.
        try FileManager.default.createDirectory(at: entries, withIntermediateDirectories: true)
        try Data([0x89]).write(to: entries.appendingPathComponent("safari.png"))
        XCTAssertTrue(changes.waitFor(2, timeout: 5),
                      "a store recreated after deletion must be noticed, not go silent")
    }

    /// A thread-safe change counter whose `waitFor` spins the main run loop, so an
    /// `onChange` delivered via `DispatchQueue.main.async` is serviced while we block.
    private final class Counter {
        private let lock = NSLock()
        private var count = 0
        func bump() { lock.lock(); count += 1; lock.unlock() }
        private var value: Int { lock.lock(); defer { lock.unlock() }; return count }
        func waitFor(_ target: Int, timeout: TimeInterval) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while value < target, Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            return value >= target
        }
    }
}
#endif
