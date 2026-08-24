#if os(Linux)
import Foundation
import Glibc
import CInotify

/// The Linux `IconStoreWatcher`: the inotify counterpart of the macOS FSEvents
/// implementation in `IconStoreWatcher.swift`. Same public surface, same contract —
/// reload-then-notify, coalesced, on the main queue.
///
/// **inotify rather than a `DispatchSource` file-object source on the directory.**
/// Every write in this store is a temp-file-plus-rename (`Data.write(options:.atomic)`),
/// so an object source armed on a single descriptor stops watching the file that
/// matters. inotify watches the *directory* by path and reports the
/// create/close/rename/delete a store write produces.
///
/// Two details the plan pins (docs/linux-port §Part 10): the `IN_*` masks are
/// hard-coded, because Swift can't import the C object-like macros as constants
/// reliably; and `struct inotify_event`'s trailing flexible array member is parsed by
/// hand out of the read buffer rather than through the imported struct.
public final class IconStoreWatcher {

    /// How long to coalesce a burst of events before delivering one `onChange`. Named
    /// and valued to match the macOS FSEvents latency, so the two platforms behave the
    /// same from a caller's point of view.
    public static let latency: TimeInterval = 0.2

    // Hard-coded inotify event masks (see the type note above).
    private enum Mask {
        static let create: UInt32     = 0x0000_0100  // IN_CREATE
        static let delete: UInt32     = 0x0000_0200  // IN_DELETE
        static let movedTo: UInt32    = 0x0000_0080  // IN_MOVED_TO
        static let movedFrom: UInt32  = 0x0000_0040  // IN_MOVED_FROM
        static let closeWrite: UInt32 = 0x0000_0008  // IN_CLOSE_WRITE
    }
    /// What a settled entries directory is watched for: any write another app makes.
    private static let directoryMask = Mask.create | Mask.movedTo | Mask.delete | Mask.closeWrite
    /// What a not-yet-existing directory's parent is watched for, to catch it appear.
    private static let parentMask = Mask.create | Mask.movedTo

    private let directory: URL
    private let onChange: () -> Void
    private let queue = DispatchQueue(label: "com.pict.store-watcher", qos: .utility)
    private let fileManager = FileManager.default

    // All of the following are touched only on `queue`.
    private var fd: Int32 = -1
    private var watch: Int32 = -1
    /// True while we're watching the parent because `directory` doesn't exist yet.
    private var watchingParent = false
    private var source: DispatchSourceRead?
    private var debounce: DispatchWorkItem?
    private var started = false

    /// - Parameters:
    ///   - store: watched at its entries directory; reloaded before `onChange` fires,
    ///     so a handler can read the new state straight away.
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
    /// nobody has set an icon, so nothing has created the store. We watch the parent
    /// until the entries directory appears, then re-arm on it (`promoteToDirectoryWatch`).
    public func start() {
        queue.sync {
            guard !started else { return }
            let descriptor = inotify_init1(O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else {
                NSLog("PictKit: couldn't start inotify; icon changes from other apps "
                      + "will not appear until relaunch.")
                return
            }
            fd = descriptor
            started = true
            armWatch()

            // The cancel handler owns the descriptor by value, so the fd is always
            // closed on stop()/deinit even if `self` is already gone.
            let owned = descriptor
            let readSource = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            readSource.setEventHandler { [weak self] in self?.drain() }
            readSource.setCancelHandler { close(owned) }
            source = readSource
            readSource.resume()
        }
    }

    public func stop() {
        queue.sync {
            guard started else { return }
            started = false
            debounce?.cancel()
            debounce = nil
            if let source {
                source.cancel()      // the cancel handler closes the descriptor
                self.source = nil
            } else if fd >= 0 {
                close(fd)
            }
            fd = -1
            watch = -1
            watchingParent = false
        }
    }

    // MARK: inotify plumbing (all on `queue`)

    /// Watches `directory` if it exists, else its parent so we notice it appear.
    private func armWatch() {
        guard fd >= 0 else { return }
        let exists = directoryExists(directory)
        let target = exists ? directory : directory.deletingLastPathComponent()
        watchingParent = !exists
        let mask = exists ? Self.directoryMask : Self.parentMask
        watch = target.path.withCString { inotify_add_watch(fd, $0, mask) }
        if watch < 0 {
            NSLog("PictKit: couldn't watch \(target.path) for icon changes.")
        }
    }

    /// Re-arms on the entries directory once it exists — we had been watching the
    /// parent. Called after an event names the directory appearing.
    private func promoteToDirectoryWatch() {
        guard watchingParent, fd >= 0, directoryExists(directory) else { return }
        if watch >= 0 { inotify_rm_watch(fd, watch) }
        watch = directory.path.withCString { inotify_add_watch(fd, $0, Self.directoryMask) }
        watchingParent = false
    }

    /// Reads every pending event (the fd is non-blocking) and, if any of them matter,
    /// schedules the debounced notify.
    private func drain() {
        guard fd >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 4096)
        var directoryAppeared = false
        var sawChange = false
        while true {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count <= 0 { break }   // -1/EAGAIN once drained
            parse(buffer, count: count, directoryAppeared: &directoryAppeared, change: &sawChange)
        }
        if watchingParent, directoryAppeared {
            promoteToDirectoryWatch()
            sawChange = true          // the store just appeared; treat it as a change
        }
        if sawChange { scheduleNotify() }
    }

    /// Walks the inotify event buffer by hand: a 16-byte header (wd, mask, cookie,
    /// len) then `len` name bytes, repeated. In parent mode only the entries directory
    /// appearing counts; once watching the directory itself, every event counts.
    private func parse(_ buffer: [UInt8], count: Int,
                       directoryAppeared: inout Bool, change: inout Bool) {
        let wantedName = directory.lastPathComponent
        buffer.withUnsafeBufferPointer { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset + 16 <= count {
                let mask = Self.readUInt32(base, offset + 4)
                let length = Int(Self.readUInt32(base, offset + 12))
                let nameStart = offset + 16
                if watchingParent {
                    if length > 0, nameStart + length <= count,
                       mask & (Mask.create | Mask.movedTo) != 0,
                       Self.name(base, at: nameStart, maxLength: length) == wantedName {
                        directoryAppeared = true
                    }
                } else {
                    change = true
                }
                offset = nameStart + length
            }
        }
    }

    private func scheduleNotify() {
        debounce?.cancel()
        let item = DispatchWorkItem { [weak self] in
            DispatchQueue.main.async { self?.onChange() }
        }
        debounce = item
        queue.asyncAfter(deadline: .now() + Self.latency, execute: item)
    }

    // MARK: Byte helpers

    /// Little-endian `UInt32` at `index` — inotify's buffer is host-endian, and the
    /// supported hosts (x86_64, aarch64) are little-endian. Read byte-wise so an
    /// unaligned offset can't trap.
    private static func readUInt32(_ p: UnsafePointer<UInt8>, _ index: Int) -> UInt32 {
        UInt32(p[index]) | (UInt32(p[index + 1]) << 8)
            | (UInt32(p[index + 2]) << 16) | (UInt32(p[index + 3]) << 24)
    }

    /// The NUL-terminated name inside an event's `len`-byte name field.
    private static func name(_ p: UnsafePointer<UInt8>, at start: Int, maxLength: Int) -> String {
        var bytes = [UInt8]()
        var i = 0
        while i < maxLength, p[start + i] != 0 {
            bytes.append(p[start + i])
            i += 1
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
#endif
