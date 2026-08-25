#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import XCTest
@testable import PictKit

/// The resolver's contract with the apps that draw from it.
///
/// Chiefly `onIconsResolved`, which is the seam that makes a change *visible*
/// rather than merely eventual: resolution is asynchronous, so a consumer that
/// redraws when it asks for an icon draws the fallback, and one that caches what
/// it drew keeps drawing the fallback long after the real artwork arrived.
final class IconResolverTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = IconTestSupport.makeTemporaryDirectory()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        super.tearDown()
    }

    /// Explicit rather than `.plain`, so these tests pin the callback's behaviour
    /// and not the shortcut's current definition of a mode.
    private static func options(scale: CGFloat) -> IconRenderOptions {
        IconRenderOptions(mode: .originalPlusCustom,
                          pixelSize: IconBitmap.pixelSize(forIconSize: 64, scale: scale),
                          scale: scale, bleed: 0,
                          trimsTransparentEdges: true, drawsShadow: false)
    }

    private func makeStore() -> IconStore {
        IconStore(directory: directory)
    }

    /// A target with a custom icon in the store. Keyed by path, like everything the
    /// apps store, so this exercises the same rung they do.
    private func seededStore(for target: IconTarget) -> IconStore {
        let store = makeStore()
        // 64 px keeps the pure-Swift PNG encode/decode cheap in the debug test build
        // (512 px made the 25-icon batch test take ~2 min on Linux); no assertion here
        // exercises image size, so the smaller fixture loses no coverage.
        let artwork = IconTestSupport.makePixelImage(width: 64, height: 64)
        guard case .success = store.setIcon(artwork, for: target) else {
            XCTFail("couldn't seed the store")
            return store
        }
        return store
    }

    private var sampleTarget: IconTarget {
        .file(URL(fileURLWithPath: "/Users/someone/Report.pdf"))
    }

    // MARK: What `plain` promises the apps with no preference

    /// Jetty and Top Drawer build their options with `.plain`, and neither has an
    /// icon-source preference. If this ever inherited `IconSourceMode.systemDefault`
    /// again, `usesCustomIcons` would be false for both and an icon set in Pict would
    /// never reach a dock tile or a drawer slot — the store shared in name only.
    ///
    /// This shipped that way once on this branch, which is why it is pinned.
    func testPlainOptionsReadCustomIcons() {
        let options = IconRenderOptions.plain(pointSize: 64, scale: 2)
        XCTAssertEqual(options.mode, .originalPlusCustom)
        XCTAssertTrue(options.mode.usesCustomIcons)
        XCTAssertTrue(options.mode.usesBundleArtwork)
    }

    /// And the version-independence that follows from it: before macOS 26 the default
    /// mode is `.system`, which switches the ladder off. A dock is not a switcher
    /// preference, so it must not be answerable to the host's OS version.
    func testPlainOptionsDoNotDependOnTheHostOSVersion() {
        // Whatever this machine is, the mode is the same one.
        XCTAssertEqual(IconRenderOptions.plain(pointSize: 64, scale: 1).mode,
                       IconRenderOptions.plain(pointSize: 128, scale: 3).mode)
        XCTAssertNotEqual(IconRenderOptions.plain(pointSize: 64, scale: 2).mode, .system)
    }

    /// A dock tile sits in a grid, so no bleed and no baked shadow. Cheap to assert
    /// and it documents the difference from Zap's switcher options.
    func testPlainOptionsAreLayoutNeutral() {
        let options = IconRenderOptions.plain(pointSize: 64, scale: 2)
        XCTAssertEqual(options.bleed, 0)
        XCTAssertFalse(options.drawsShadow)
    }

    // MARK: The callback

    /// The whole point: ask, get `nil`, and be told when that answer has changed.
    func testResolvingArtworkNotifies() {
        let target = sampleTarget
        let resolver = IconResolver(options: Self.options(scale: 2),
                                    store: seededStore(for: target))

        let resolved = expectation(description: "artwork landed")
        resolver.onIconsResolved = { resolved.fulfill() }

        // The first ask is a miss by design — it returns nil and schedules the work.
        XCTAssertNil(resolver.icon(for: target))
        wait(for: [resolved], timeout: 5)

        // And by the time we were told, the answer really had changed.
        XCTAssertNotNil(resolver.icon(for: target))
    }

    /// A target the resolver has nothing to say about must not wake every consumer.
    /// `.useSystemIcon` is already what they are drawing, so a notification would be
    /// a redraw that changes no pixel — and on Jetty's dock, a cache flush too.
    func testResolvingToTheSystemIconDoesNotNotify() {
        // Nothing seeded, and no bundle behind it, so this resolves to "use the
        // system icon" rather than to artwork.
        let resolver = IconResolver(options: Self.options(scale: 2),
                                    store: makeStore())

        let quiet = expectation(description: "no notification")
        quiet.isInverted = true
        resolver.onIconsResolved = { quiet.fulfill() }

        XCTAssertNil(resolver.icon(for: sampleTarget))
        wait(for: [quiet], timeout: 1)
    }

    /// Invalidation re-warms in the background, so the notification has to come from
    /// the *landing*, not from the invalidation. This is the screen-change case:
    /// options change, everything re-renders, and the dock is told once it can read
    /// artwork at the new scale rather than at the moment its cache went empty.
    func testChangingOptionsNotifiesOnceTheRerenderLands() {
        let target = sampleTarget
        let resolver = IconResolver(options: Self.options(scale: 1),
                                    store: seededStore(for: target))

        let firstPass = expectation(description: "initial resolve")
        resolver.onIconsResolved = { firstPass.fulfill() }
        XCTAssertNil(resolver.icon(for: target))
        wait(for: [firstPass], timeout: 5)

        let rerendered = expectation(description: "re-rendered at the new scale")
        resolver.onIconsResolved = { rerendered.fulfill() }
        resolver.update(Self.options(scale: 3))
        wait(for: [rerendered], timeout: 5)

        XCTAssertEqual(resolver.currentOptions.scale, 3)
        XCTAssertNotNil(resolver.icon(for: target))
    }

    /// Identical options are a comparison and a return, so nothing re-renders and
    /// nobody is woken. Guards the "cheap to call on every settings change" claim.
    func testUnchangedOptionsDoNotNotify() {
        let target = sampleTarget
        let options = Self.options(scale: 2)
        let resolver = IconResolver(options: options, store: seededStore(for: target))

        let firstPass = expectation(description: "initial resolve")
        resolver.onIconsResolved = { firstPass.fulfill() }
        XCTAssertNil(resolver.icon(for: target))
        wait(for: [firstPass], timeout: 5)

        let quiet = expectation(description: "no second notification")
        quiet.isInverted = true
        resolver.onIconsResolved = { quiet.fulfill() }
        resolver.update(options)
        wait(for: [quiet], timeout: 1)
    }

    /// Delivered on the main queue, because every consumer of it touches UI —
    /// dropping an `@Published` cache, re-listing a drawer. The resolver's own work
    /// happens on a utility queue, so this is a real hop and worth pinning.
    func testTheCallbackArrivesOnTheMainQueue() {
        let target = sampleTarget
        let resolver = IconResolver(options: Self.options(scale: 2),
                                    store: seededStore(for: target))

        let onMain = expectation(description: "delivered on main")
        resolver.onIconsResolved = {
            XCTAssertTrue(Thread.isMainThread)
            dispatchPrecondition(condition: .onQueue(.main))
            onMain.fulfill()
        }

        XCTAssertNil(resolver.icon(for: target))
        wait(for: [onMain], timeout: 5)
    }

    /// Warming a batch settles, resolves everything, and never wakes a consumer more
    /// than once per landing.
    ///
    /// Deliberately not asserting a strict reduction. Coalescing is per runloop hop,
    /// and the resolver's queue is serial, so a fast main queue can legitimately
    /// drain one notification between each resolve — a `count < targets.count`
    /// assertion would be testing the CI machine's scheduling, not the resolver. The
    /// ceiling is the part that is actually guaranteed, and it is the part that
    /// matters: the redraw is bounded by the work, not by a re-entrant cascade.
    func testABatchSettlesWithoutANotificationStorm() {
        let store = makeStore()
        let artwork = IconTestSupport.makePixelImage(width: 64, height: 64)
        var targets: [IconTarget] = []
        for index in 0..<25 {
            let target = IconTarget.file(URL(fileURLWithPath: "/Users/someone/File\(index).pdf"))
            guard case .success = store.setIcon(artwork, for: target) else {
                return XCTFail("couldn't seed \(index)")
            }
            targets.append(target)
        }

        let resolver = IconResolver(options: Self.options(scale: 2), store: store)
        let settled = expectation(description: "batch settled")
        let counter = NotificationCounter(expectation: settled)
        resolver.onIconsResolved = { counter.record() }

        resolver.warm(targets)
        wait(for: [settled], timeout: 10)

        for target in targets { XCTAssertNotNil(resolver.icon(for: target)) }
        XCTAssertGreaterThan(counter.count, 0, "the batch should have woken the consumer")
        XCTAssertLessThanOrEqual(counter.count, targets.count,
                                 "no consumer should be woken more than once per landing")
    }
}

/// Counts notifications and fulfils once the work behind them is done.
///
/// A plain `var` captured by the callback would be a data race under TSan; the
/// callback is main-queue-only, but the assertions read it from the test thread
/// after `wait`, so the lock is what makes that read legal rather than merely
/// true in practice.
private final class NotificationCounter {
    private let lock = NSLock()
    private var notifications = 0
    private var fulfilled = false
    private let expectation: XCTestExpectation

    init(expectation: XCTestExpectation) {
        self.expectation = expectation
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return notifications
    }

    /// Fulfils on the first notification that arrives after a settling delay with no
    /// further work pending — approximated by waiting one more hop and checking that
    /// the count stopped moving.
    func record() {
        lock.lock()
        notifications += 1
        let seen = notifications
        lock.unlock()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [self] in
            lock.lock()
            let unchanged = notifications == seen
            let shouldFulfil = unchanged && !fulfilled
            if shouldFulfil { fulfilled = true }
            lock.unlock()
            if shouldFulfil { expectation.fulfill() }
        }
    }
}
