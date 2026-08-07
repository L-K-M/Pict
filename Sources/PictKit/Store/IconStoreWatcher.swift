import CoreServices
import Foundation

/// Notices when another process changes the shared store.
///
/// This is what makes the store *shared* rather than merely *common*: without it,
/// Zap would show an icon Pict replaced ten seconds ago until Zap was relaunched.
///
/// **FSEvents rather than `DispatchSource.makeFileSystemObjectSource`.** A dispatch
/// source watches a file descriptor, and every write in this store is a rename
/// (`Data.write(options: .atomic)`), so the descriptor a source was armed on stops
/// being the file that matters. Watching the *directory* that way means re-arming by
/// hand on every event and racing the next one. FSEvents watches a path, survives
/// renames, coalesces bursts, and is the API this case is for.
///
/// No permission is involved: all four apps are unsandboxed and this is a directory
/// in the user's own Application Support, which is not TCC-protected.
public final class IconStoreWatcher {

    /// How long FSEvents may batch events before delivering them. Short enough that
    /// an icon set in Pict lands in the other apps while the user is still looking at
    /// them, long enough that writing several icons at once is one callback.
    public static let latency: CFTimeInterval = 0.2

    private let directory: URL
    private let onChange: () -> Void
    private let queue = DispatchQueue(label: "com.pict.store-watcher", qos: .utility)
    private var stream: FSEventStreamRef?

    /// - Parameters:
    ///   - store: watched at its entries directory; reloaded before `onChange` fires,
    ///     so a handler can read the new state straight away rather than having to
    ///     know it must reload first.
    ///   - onChange: called on the main queue after the store has been reloaded.
    public convenience init(store: IconStore, onChange: @escaping () -> Void) {
        self.init(directory: store.entriesDirectory) { [weak store] in
            store?.reload()
            onChange()
        }
    }

    public init(directory: URL, onChange: @escaping () -> Void) {
        self.directory = directory
        self.onChange = onChange
    }

    deinit { stop() }

    /// Starts watching. Safe to call twice; the second call does nothing.
    ///
    /// Watching a directory that does not exist yet is the normal first-run case —
    /// nobody has set an icon, so nothing has created it. `kFSEventStreamCreateFlagWatchRoot`
    /// is what makes that work: the stream reports the root appearing, rather than
    /// silently watching a path that never resolves.
    public func start() {
        guard stream == nil else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)

        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagWatchRoot
            | kFSEventStreamCreateFlagIgnoreSelf)

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, _, _, _, _ in
                guard let info else { return }
                let watcher = Unmanaged<IconStoreWatcher>.fromOpaque(info).takeUnretainedValue()
                watcher.deliver()
            },
            &context,
            [directory.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            Self.latency,
            flags
        ) else {
            NSLog("PictKit: couldn't watch the shared icon store; changes from other apps "
                  + "will not appear until relaunch.")
            return
        }

        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// **`onChange` is always called on the main queue.** FSEvents delivers on the
    /// stream's own dispatch queue — a utility one, above — and this is the hop.
    /// Callers therefore need no dispatch of their own, and adding one only delays
    /// the invalidation by a runloop turn. The guarantee is stated here because the
    /// apps that depend on it are in other modules and cannot see this hop.
    ///
    /// `kFSEventStreamCreateFlagIgnoreSelf` drops this process's own writes, so an
    /// app that just set an icon doesn't invalidate its cache over its own change.
    /// It does not help with *another* process, which is the case this exists for.
    private func deliver() {
        DispatchQueue.main.async { [weak self] in
            self?.onChange()
        }
    }
}
