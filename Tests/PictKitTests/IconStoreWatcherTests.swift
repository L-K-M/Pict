#if os(Linux)
import Foundation
import XCTest
@testable import PictKit

/// The Linux inotify `IconStoreWatcher`: a write into the watched directory must
/// reach `onChange`, delivered on the main queue like the macOS FSEvents path.
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

        let latch = Latch()
        let watcher = IconStoreWatcher(directory: entries) { latch.signal() }
        watcher.start()
        defer { watcher.stop() }

        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: entries.appendingPathComponent("safari.png"))

        XCTAssertTrue(latch.wait(timeout: 5),
                      "a file written into the watched store should reach onChange")
    }

    /// The first-run case: the entries directory doesn't exist when watching starts,
    /// so the watcher follows the parent until it appears, then re-arms on it.
    func testFollowsTheParentUntilTheStoreDirectoryAppears() throws {
        let entries = directory.appendingPathComponent("entries", isDirectory: true)
        // Deliberately not created yet — start() must watch the parent.

        let latch = Latch()
        let watcher = IconStoreWatcher(directory: entries) { latch.signal() }
        watcher.start()
        defer { watcher.stop() }

        try FileManager.default.createDirectory(at: entries, withIntermediateDirectories: true)
        try Data([0x89]).write(to: entries.appendingPathComponent("safari.png"))

        XCTAssertTrue(latch.wait(timeout: 5),
                      "the watcher should notice the store directory being created")
    }

    /// A thread-safe latch whose `wait` spins the main run loop, so an `onChange`
    /// delivered via `DispatchQueue.main.async` is actually serviced while we block.
    private final class Latch {
        private let lock = NSLock()
        private var fired = false
        func signal() { lock.lock(); fired = true; lock.unlock() }
        private var isSet: Bool { lock.lock(); defer { lock.unlock() }; return fired }
        func wait(timeout: TimeInterval) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while !isSet, Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            return isSet
        }
    }
}
#endif
