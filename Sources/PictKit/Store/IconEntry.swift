import Foundation

/// One override: what the user chose for one target, and where it came from.
///
/// Treated as untrusted input on every load. An entry can be hand-edited, can arrive
/// inside a shared icon pack, and names a file the reader goes on to open — so
/// `validated(in:)` clamps every number, falls back on every unparseable enum, and
/// drops any entry whose image name could escape the store directory.
///
/// **Every field is optional and decoding is lenient by design.** Three
/// independently released apps read this directory, so a build from six months ago
/// will meet entries written by one from next week. An unknown field must cost that
/// reader nothing worse than a default — see `IconStore`'s note on why a reader that
/// does not fully understand an entry must never rewrite it.
public struct IconEntry: Codable, Equatable, Sendable {

    /// Bumped only for a change that an older reader could misinterpret. Adding an
    /// optional field is not one of those; removing or repurposing one is.
    public static let currentVersion = 1

    /// Where an icon came from.
    public enum Origin: String, Codable, Equatable, CaseIterable, Sendable {
        /// A file the user picked, dropped, or dragged in from a browser.
        case file
        /// A result from a search provider.
        case search
        /// An icon adopted from an installed theme.
        case theme
        /// The target's own recovered artwork, adopted explicitly.
        case originalArtwork
        /// Pinned to the system icon — this target opts out of substitution entirely.
        case system

        /// Whether an entry with this origin names an image in the store directory.
        public var needsImage: Bool { self != .system }
    }

    public var version: Int?
    /// The key this entry is for, recorded verbatim so the index can be rebuilt from
    /// the files alone — there is no manifest to be the index (`PLAN.md §3`).
    public var key: String?
    /// Image file name only, never a path — resolved against the store directory and
    /// bounds-checked on load.
    public var image: String?
    public var source: String?
    public var provider: String?
    public var credit: String?
    public var creditURL: String?
    public var license: String?
    public var addedAt: Date?
    /// Which app wrote this. Costs nothing and makes the directory self-explaining
    /// when someone opens it wondering what put a PNG there.
    public var writtenBy: String?
    /// Per-target override of the global bleed.
    public var bleed: Double?
    /// Per-target override of "trim transparent edges".
    public var trim: Bool?

    public init(version: Int? = IconEntry.currentVersion,
                key: String? = nil,
                image: String? = nil,
                source: String? = nil,
                provider: String? = nil,
                credit: String? = nil,
                creditURL: String? = nil,
                license: String? = nil,
                addedAt: Date? = nil,
                writtenBy: String? = nil,
                bleed: Double? = nil,
                trim: Bool? = nil) {
        self.version = version
        self.key = key
        self.image = image
        self.source = source
        self.provider = provider
        self.credit = credit
        self.creditURL = creditURL
        self.license = license
        self.addedAt = addedAt
        self.writtenBy = writtenBy
        self.bleed = bleed
        self.trim = trim
    }

    /// The parsed origin, falling back to `.file` for anything unrecognised — an
    /// entry written by a newer build naming an origin this one has never heard of
    /// still resolves to "there is an image, use it".
    public var origin: Origin {
        source.flatMap(Origin.init(rawValue:)) ?? .file
    }

    /// The parsed key, or `nil` when it is missing or unparseable.
    public var entryKey: IconEntryKey? {
        key.flatMap(IconEntryKey.init(serialized:))
    }

    /// Whether this build understands the entry well enough to *rewrite* it.
    ///
    /// A reader that rewrites an entry it only partly understood silently drops the
    /// fields it didn't know about, which is how a newer build's work disappears the
    /// first time an older one touches it. `IconStore` refuses to overwrite in place
    /// when this is false; the user's own action still wins, because that replaces
    /// the entry outright rather than editing it.
    public var isFullyUnderstood: Bool {
        (version ?? IconEntry.currentVersion) <= IconEntry.currentVersion
    }

    // MARK: Validation

    /// The widest bleed a per-target override may request.
    public static let maximumBleed = 0.15

    /// Returns a copy safe to act on, or `nil` if the entry cannot name anything
    /// real: unparseable origins normalised, numbers clamped, and the image name
    /// dropped unless it is a bare, in-directory PNG.
    public func validated(in directory: URL) -> IconEntry? {
        guard let key, IconEntryKey(serialized: key) != nil else { return nil }

        var safe = self
        safe.key = key
        safe.source = origin.rawValue
        safe.bleed = bleed.flatMap { value in
            value.isFinite ? Swift.min(Swift.max(value, 0), Self.maximumBleed) : nil
        }

        if origin.needsImage {
            guard let image,
                  IconEntryKey.resolvedURL(forFile: image, in: directory,
                                           extensions: IconStore.imageExtensions) != nil
            else { return nil }
            safe.image = image
        } else {
            // A system pin names no image, so drop any it happens to carry.
            safe.image = nil
        }
        return safe
    }
}
