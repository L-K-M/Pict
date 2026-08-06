import CoreGraphics
import Foundation

/// The shared store: the user's icon overrides, in one directory that Zap, Jetty,
/// Top Drawer and Pict all read.
///
/// **One file per entry, not one manifest.** Zap kept a single `manifest.json`,
/// which is a single-writer design: three processes read-modify-writing it will lose
/// entries — Zap reads it, Jetty writes it, Zap writes its stale copy back.
/// `NSFileCoordinator` would fix that and would add a coordination protocol to every
/// read on a path that has to stay cheap. Splitting the manifest removes the problem
/// instead of managing it:
///
/// - Two apps overriding two different targets touch two different files and cannot
///   conflict at all.
/// - Two apps overriding the *same* target resolve by last-writer-wins, which is the
///   correct semantics for "the user set this icon" and needs no lock to be right.
/// - Every write is a temp file plus a rename, so no reader ever sees half a file.
/// - The directory listing **is** the index. There is no index to keep in step.
///
/// A half-finished delete leaves a JSON whose PNG is missing; that fails validation
/// and the resolver falls through to the next rung, which is exactly right.
///
/// Safe to read from a background queue — `IconResolver` warms its cache off the main
/// thread while the editor mutates the same store from another process entirely.
public final class IconStore {

    /// The store's root. `entries/` lives inside it.
    public let directory: URL

    /// Which image formats an entry may name. Only PNG: everything in here is Pict's
    /// own re-encoded output (`PLAN.md §4`), so an entry naming anything else was not
    /// written by this family of apps and should not be opened.
    public static let imageExtensions: Set<String> = ["png"]

    private let fileManager: FileManager
    private let lock = NSLock()
    private var index: [IconEntryKey: IconEntry] = [:]

    // MARK: Lifecycle

    public init(directory: URL = IconStoreLocation.defaultDirectory(),
                fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
        self.index = Self.load(from: directory.appendingPathComponent("entries", isDirectory: true),
                               fileManager: fileManager)
    }

    /// Where the per-entry files live.
    public var entriesDirectory: URL {
        directory.appendingPathComponent("entries", isDirectory: true)
    }

    // MARK: Reading

    /// Every valid entry, keyed.
    public var entries: [IconEntryKey: IconEntry] {
        lock.lock()
        defer { lock.unlock() }
        return index
    }

    public func entry(for key: IconEntryKey) -> IconEntry? {
        lock.lock()
        defer { lock.unlock() }
        return index[key]
    }

    /// The entry that applies to `target`, walking its lookup ladder — the app's own
    /// path first, then the identifier it may also be stored under.
    public func entry(for target: IconTarget) -> IconEntry? {
        let ladder = IconEntryKey.lookupLadder(for: target)
        lock.lock()
        defer { lock.unlock() }
        for key in ladder {
            if let entry = index[key] { return entry }
        }
        return nil
    }

    /// Whether this target is pinned to the system icon, opting out of substitution.
    public func isPinnedToSystemIcon(_ target: IconTarget) -> Bool {
        entry(for: target)?.origin == .system
    }

    /// The stored image for `target`, bounds-checked against the store directory.
    public func imageURL(for target: IconTarget) -> URL? {
        guard let entry = entry(for: target), entry.origin.needsImage,
              let image = entry.image else { return nil }
        return IconEntryKey.resolvedURL(forFile: image, in: entriesDirectory,
                                        extensions: Self.imageExtensions)
    }

    /// Decodes the override for `target`, or `nil` when there isn't one.
    public func image(for target: IconTarget) -> CGImage? {
        guard let url = imageURL(for: target) else { return nil }
        switch IconImageValidator.decode(contentsOf: url) {
        case .success(let image): return image
        case .failure: return nil
        }
    }

    /// Re-reads the directory, discarding any in-memory state. Called by
    /// `IconStoreWatcher` when another process writes.
    public func reload() {
        let loaded = Self.load(from: entriesDirectory, fileManager: fileManager)
        lock.lock()
        index = loaded
        lock.unlock()
    }

    // MARK: Writing

    /// Why a write didn't happen.
    public enum WriteFailure: Error, Equatable {
        /// The image was rejected — too big, unreadable, not encodable.
        case rejected(IconImageValidator.Rejection)
        /// The store directory couldn't be created or written to.
        case directoryUnavailable
        /// The target has no key to store under (an app with neither path nor id).
        case unkeyable
    }

    /// Adopts an already-decoded image as `target`'s icon.
    ///
    /// Takes an image rather than a file URL on purpose, and this is load-bearing
    /// rather than fastidious. Turning something the user supplied into an image is
    /// ingestion's job, it lives in Pict, and it can no longer be done synchronously —
    /// SVG has to go through a web view first. A convenience overload here that
    /// quietly decoded a URL with ImageIO would be a second ingestion path that
    /// silently refused every SVG, which is the bug this arrangement exists to make
    /// unrepeatable.
    @discardableResult
    public func setIcon(_ image: CGImage, for target: IconTarget,
                        origin: IconEntry.Origin = .file,
                        provider: String? = nil, credit: String? = nil,
                        creditURL: String? = nil, license: String? = nil,
                        writtenBy: String = IconStoreLocation.callingAppName,
                        now: Date = Date()) -> Result<IconEntry, WriteFailure> {
        guard let key = IconEntryKey.storageKey(for: target) else { return .failure(.unkeyable) }

        do {
            try fileManager.createDirectory(at: entriesDirectory, withIntermediateDirectories: true)
        } catch {
            NSLog("PictKit: couldn't create the icon store directory: %@", error.localizedDescription)
            return .failure(.directoryUnavailable)
        }
        IconStoreLocation.seedReadMe(in: directory, fileManager: fileManager)

        let imageName = "\(key.fileStem).png"
        guard let imageURL = IconEntryKey.resolvedURL(forFile: imageName, in: entriesDirectory,
                                                      extensions: Self.imageExtensions) else {
            return .failure(.rejected(.notEncodable))
        }
        if case .failure(let rejection) = IconImageValidator.writePNG(image, to: imageURL) {
            return .failure(.rejected(rejection))
        }

        let entry = IconEntry(key: key.serialized, image: imageName, source: origin.rawValue,
                              provider: provider, credit: credit, creditURL: creditURL,
                              license: license, addedAt: now, writtenBy: writtenBy)

        guard write(entry, for: key) else { return .failure(.directoryUnavailable) }
        retireLessSpecificKeys(for: target, keeping: key)
        return .success(entry)
    }

    /// Pins `target` to the system icon — no substitution, no recovery, no override.
    ///
    /// The one write that needs no image handling at all, which is why it can stay in
    /// an app that has shed its ingestion code.
    @discardableResult
    public func pinToSystemIcon(for target: IconTarget,
                                writtenBy: String = IconStoreLocation.callingAppName,
                                now: Date = Date()) -> Bool {
        guard let key = IconEntryKey.storageKey(for: target) else { return false }
        removeImage(for: key)
        let entry = IconEntry(key: key.serialized, source: IconEntry.Origin.system.rawValue,
                              addedAt: now, writtenBy: writtenBy)
        guard write(entry, for: key) else { return false }
        retireLessSpecificKeys(for: target, keeping: key)
        return true
    }

    /// Drops the override for `target`, returning it to the global setting's
    /// behaviour, and deletes the stored image.
    ///
    /// Clears **every** key the target could be stored under. Clearing only the most
    /// specific one would leave a less specific entry to surface on the next lookup,
    /// which reads as an icon that refuses to go away.
    public func clear(for target: IconTarget) {
        for key in IconEntryKey.lookupLadder(for: target) { clear(for: key) }
    }

    public func clear(for key: IconEntryKey) {
        removeImage(for: key)
        if let url = entryURL(for: key) { try? fileManager.removeItem(at: url) }
        lock.lock()
        index[key] = nil
        lock.unlock()
    }

    /// Writes an entry that already exists in full — a migrated one, or one arriving
    /// from an imported pack — without going back through ingestion.
    ///
    /// Deliberately narrow. The image it names must already be in the entries
    /// directory; this does not put it there. A caller holding a *picture* wants
    /// `setIcon(_:for:)`, which is the path with the validation on it.
    ///
    /// Refuses to overwrite an entry this build does not fully understand
    /// (`IconEntry.isFullyUnderstood`): a newer app's entry rewritten by an older one
    /// silently loses whatever fields the older one had never heard of, which is the
    /// failure mode three independently released readers make possible. A user's own
    /// action still wins, because `setIcon` and `pinToSystemIcon` replace an entry
    /// outright rather than editing it.
    @discardableResult
    public func adopt(_ entry: IconEntry, for key: IconEntryKey) -> Bool {
        if let existing = self.entry(for: key), !existing.isFullyUnderstood {
            NSLog("PictKit: leaving an icon entry written by a newer build alone.")
            return false
        }
        guard entry.validated(in: entriesDirectory) != nil else { return false }
        return write(entry, for: key)
    }

    /// Drops every override and deletes every stored image. Leaves the directory and
    /// its README in place.
    ///
    /// **Prefer `removeAll(kinds:)`.** In a store four apps read, an unscoped reset
    /// reaches further than the app offering it: Zap lists applications and cannot
    /// draw a file or a link at all, so a "Reset All Icons" there that also deleted
    /// Top Drawer's folder icons would destroy work the user cannot even see from
    /// the button they pressed. This overload is right for Pict, which lists
    /// everything, and for tests.
    public func removeAll() {
        let keys = Array(entries.keys)
        for key in keys { clear(for: key) }
    }

    /// Drops every override of the given kinds.
    ///
    /// The scoping rule is *if you do not list it, do not delete it*: an app resets
    /// what it shows the user and nothing else. Zap passes the application kinds
    /// because application rows are the whole of its list.
    ///
    /// Returns how many entries were removed, so the caller can say so before doing
    /// it — a shared store makes "reset" a question worth asking out loud.
    @discardableResult
    public func removeAll(kinds: Set<IconEntryKey.Kind>) -> Int {
        let keys = entries.keys.filter { kinds.contains($0.kind) }
        for key in keys { clear(for: key) }
        return keys.count
    }

    /// How many entries of the given kinds are stored — what a confirmation needs to
    /// name before `removeAll(kinds:)` is called.
    public func count(kinds: Set<IconEntryKey.Kind>) -> Int {
        entries.keys.filter { kinds.contains($0.kind) }.count
    }

    // MARK: Private

    private func entryURL(for key: IconEntryKey) -> URL? {
        IconEntryKey.resolvedURL(forFile: "\(key.fileStem).json", in: entriesDirectory,
                                 extensions: ["json"])
    }

    private func removeImage(for key: IconEntryKey) {
        guard let url = IconEntryKey.resolvedURL(forFile: "\(key.fileStem).png",
                                                 in: entriesDirectory,
                                                 extensions: Self.imageExtensions) else { return }
        try? fileManager.removeItem(at: url)
    }

    /// Writes one entry atomically and indexes it. `false` if it couldn't be written,
    /// in which case the in-memory index is left alone rather than claiming a state
    /// the disk doesn't have.
    private func write(_ entry: IconEntry, for key: IconEntryKey) -> Bool {
        guard let url = entryURL(for: key) else { return false }
        do {
            try fileManager.createDirectory(at: entriesDirectory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            // `.atomic` is a write-to-temp plus a rename, so a concurrent reader in
            // another process sees either the old file or the new one, never a
            // partial write. This is the whole concurrency story.
            try encoder.encode(entry).write(to: url, options: .atomic)
        } catch {
            NSLog("PictKit: couldn't write an icon entry: %@", error.localizedDescription)
            return false
        }
        lock.lock()
        index[key] = entry
        lock.unlock()
        return true
    }

    /// After writing the most specific key for a target, drops the vaguer ones.
    ///
    /// Without this, giving an app an icon by path would leave an older
    /// identifier-keyed entry in place — invisible, because the path wins the ladder,
    /// until the app moves and the stale icon reappears. Zap hit exactly this when it
    /// moved from identifier keys to path keys, and solved it the same way.
    private func retireLessSpecificKeys(for target: IconTarget, keeping kept: IconEntryKey) {
        for key in IconEntryKey.lookupLadder(for: target) where key != kept {
            clear(for: key)
        }
    }

    /// Lists the entries directory and builds the index.
    ///
    /// Every failure mode here is "skip this entry", never "fail the load". One
    /// unreadable file must not cost the user every other icon they set.
    private static func load(from entriesDirectory: URL, fileManager: FileManager)
        -> [IconEntryKey: IconEntry] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: entriesDirectory.path) else {
            return [:]
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var index: [IconEntryKey: IconEntry] = [:]
        for name in names where (name as NSString).pathExtension.lowercased() == "json" {
            guard let url = IconEntryKey.resolvedURL(forFile: name, in: entriesDirectory,
                                                     extensions: ["json"]),
                  let data = try? Data(contentsOf: url),
                  let decoded = try? decoder.decode(IconEntry.self, from: data),
                  let entry = decoded.validated(in: entriesDirectory),
                  let key = entry.entryKey
            else { continue }

            // An entry whose image has gone — a half-finished delete, or a store
            // someone copied without its PNGs — is not an entry.
            if entry.origin.needsImage {
                guard let image = entry.image,
                      let imageURL = IconEntryKey.resolvedURL(forFile: image, in: entriesDirectory,
                                                              extensions: imageExtensions),
                      fileManager.fileExists(atPath: imageURL.path)
                else { continue }
            }
            index[key] = entry
        }
        return index
    }
}
