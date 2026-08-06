import Foundation

/// Carries a Zap installation's existing icons into the shared store, once.
///
/// Zap has shipped `~/Library/Application Support/Zap/Icons/manifest.json` since its
/// first icon release, so there are real user choices to bring across — this is not
/// a hypothetical upgrade path. The old layout was a single manifest keyed by either
/// a bundle path or a bundle identifier, with one PNG per entry beside it.
///
/// **Not a symlink from the old location to the new.** Two writers and one inode is
/// exactly the ambiguity the entry-per-file design removes (`IconStore`), and a
/// symlink would reintroduce it for the one release where both layouts exist.
///
/// **Not a delete, either.** The old directory is renamed rather than removed, so a
/// user who downgrades still has their icons and a user who hits a bug in this code
/// has something to point at. One release later it can go.
public enum ZapManifestImport {

    /// What the import did, for the log line and for the tests.
    public struct Outcome: Equatable {
        public var imported: Int
        public var skipped: Int
        /// Where the old directory was moved to, when anything was moved.
        public var archivedAt: URL?

        public init(imported: Int = 0, skipped: Int = 0, archivedAt: URL? = nil) {
            self.imported = imported
            self.skipped = skipped
            self.archivedAt = archivedAt
        }

        public static let nothingToDo = Outcome()
    }

    /// Zap's old icons directory.
    public static func legacyDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("Zap/Icons", isDirectory: true)
    }

    /// Imports every entry from `legacyDirectory` into `store`, then archives the old
    /// directory. Safe to call on every launch: once the old directory is archived
    /// there is nothing to find, so the second call is a `fileExists` and a return.
    ///
    /// An entry already present in the shared store **wins** and the legacy one is
    /// skipped. The shared store is the newer decision by construction — the user
    /// cannot have written it before the migration that created it — and clobbering it
    /// would mean a second Mac syncing an old manifest could undo a fresh choice.
    @discardableResult
    public static func run(into store: IconStore,
                           from legacyDirectory: URL = ZapManifestImport.legacyDirectory(),
                           fileManager: FileManager = .default,
                           now: Date = Date()) -> Outcome {
        let manifestURL = legacyDirectory.appendingPathComponent("manifest.json")
        guard fileManager.fileExists(atPath: manifestURL.path) else { return .nothingToDo }

        guard let data = try? Data(contentsOf: manifestURL) else { return .nothingToDo }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let legacy = try? decoder.decode(LegacyManifest.self, from: data) else {
            NSLog("PictKit: Zap's old icon manifest couldn't be parsed; leaving it in place.")
            return .nothingToDo
        }

        var outcome = Outcome()
        for (legacyKey, entry) in legacy.entries {
            guard let key = Self.key(forLegacyKey: legacyKey) else { outcome.skipped += 1; continue }
            guard store.entry(for: key) == nil else { outcome.skipped += 1; continue }

            let origin = IconEntry.Origin(rawValue: entry.source ?? "") ?? .file
            if origin.needsImage {
                guard let file = entry.file,
                      let source = IconEntryKey.resolvedURL(forFile: file, in: legacyDirectory,
                                                            extensions: IconStore.imageExtensions),
                      let image = try? Data(contentsOf: source), !image.isEmpty
                else { outcome.skipped += 1; continue }

                guard copyImage(image, for: key, into: store, fileManager: fileManager) else {
                    outcome.skipped += 1; continue
                }
            }

            // Written straight rather than through `setIcon`: the PNG is already
            // Zap's own validated output, so re-decoding and re-encoding it would
            // cost a generation of quality to prove something already known.
            let migrated = IconEntry(key: key.serialized,
                                     image: origin.needsImage ? "\(key.fileStem).png" : nil,
                                     source: origin.rawValue,
                                     provider: entry.provider,
                                     credit: entry.credit,
                                     creditURL: entry.creditURL,
                                     license: entry.license,
                                     addedAt: entry.addedAt ?? now,
                                     writtenBy: "Zap (migrated)",
                                     bleed: entry.bleed,
                                     trim: entry.trim)
            if store.adopt(migrated, for: key) {
                outcome.imported += 1
            } else {
                outcome.skipped += 1
            }
        }

        outcome.archivedAt = archive(legacyDirectory, fileManager: fileManager, now: now)
        NSLog("PictKit: migrated %d icon(s) from Zap's store, skipped %d.",
              outcome.imported, outcome.skipped)
        return outcome
    }

    // MARK: Private

    /// Zap keyed by bundle *path* when it knew one and by bundle *identifier* when it
    /// didn't, distinguished by a leading slash — `IconIdentity.isPath(_:)`. That maps
    /// exactly onto the two application kinds of `IconEntryKey`.
    static func key(forLegacyKey legacyKey: String) -> IconEntryKey? {
        guard !legacyKey.isEmpty, !legacyKey.contains("\0") else { return nil }
        if legacyKey.hasPrefix("/") {
            return .app(at: URL(fileURLWithPath: legacyKey))
        }
        return .app(bundleIdentifier: legacyKey)
    }

    private static func copyImage(_ image: Data, for key: IconEntryKey, into store: IconStore,
                                  fileManager: FileManager) -> Bool {
        guard let destination = IconEntryKey.resolvedURL(forFile: "\(key.fileStem).png",
                                                         in: store.entriesDirectory,
                                                         extensions: IconStore.imageExtensions)
        else { return false }
        do {
            try fileManager.createDirectory(at: store.entriesDirectory, withIntermediateDirectories: true)
            try image.write(to: destination, options: .atomic)
            return true
        } catch {
            NSLog("PictKit: couldn't copy a migrated icon: %@", error.localizedDescription)
            return false
        }
    }

    /// Renames the old directory out of the way so the migration doesn't run twice.
    private static func archive(_ directory: URL, fileManager: FileManager, now: Date) -> URL? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        let destination = directory.deletingLastPathComponent()
            .appendingPathComponent("Icons.migrated-\(formatter.string(from: now))",
                                    isDirectory: true)
        do {
            try fileManager.moveItem(at: directory, to: destination)
            return destination
        } catch {
            NSLog("PictKit: couldn't archive Zap's old icon directory: %@", error.localizedDescription)
            return nil
        }
    }

    // MARK: The old format

    /// Only the fields the migration reads. Deliberately a private mirror rather than
    /// a dependency on Zap's type: the old format is frozen, and a copy that cannot
    /// change is a smaller commitment than a shared type two repositories must agree
    /// about forever.
    struct LegacyManifest: Decodable {
        var entries: [String: LegacyEntry]
    }

    struct LegacyEntry: Decodable {
        var file: String?
        var source: String?
        var provider: String?
        var credit: String?
        var creditURL: String?
        var license: String?
        var addedAt: Date?
        var bleed: Double?
        var trim: Bool?
    }
}
