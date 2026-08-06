import Foundation

/// What an icon override is *for*.
///
/// Zap keyed overrides on `IconIdentity` — a bundle path, falling back to the
/// bundle identifier. That works because a switcher only ever draws applications.
/// Jetty and Top Drawer draw files, folders and links too, so the key generalises
/// to a discriminated pair rather than a bare string.
///
/// The serialised form is `kind:value` — `app:/Applications/Safari.app` — which is
/// what a stored entry records and what the lookup ladder is built from.
public struct IconEntryKey: Hashable, Codable, Sendable {

    /// What sort of thing is being overridden.
    ///
    /// The distinction is not decoration: it decides the *lookup ladder*. An
    /// application is looked up by path and then by identifier; nothing else has a
    /// second chance, because nothing else has two names.
    public enum Kind: String, Codable, CaseIterable, Sendable {
        /// An application bundle, named by its standardised path.
        case app
        /// An application named by its bundle identifier — "this app wherever it
        /// lives". Never overrides an `app` entry; see `lookupLadder(for:)`.
        case bundleID
        /// A file or folder, named by its standardised path.
        case file
        /// A link, named by its normalised absolute URL string.
        case url
    }

    public let kind: Kind
    public let value: String

    public init(kind: Kind, value: String) {
        self.kind = kind
        self.value = value
    }

    // MARK: Making one

    /// An application at a known location. The path is standardised so
    /// `/Applications/./Safari.app` and `/Applications/Safari.app` are one key —
    /// the same reason `IconIdentity` standardised its storage key.
    public static func app(at bundleURL: URL) -> IconEntryKey {
        IconEntryKey(kind: .app, value: bundleURL.standardizedFileURL.path)
    }

    /// An application known only by identifier.
    public static func app(bundleIdentifier: String) -> IconEntryKey {
        IconEntryKey(kind: .bundleID, value: bundleIdentifier)
    }

    public static func file(at url: URL) -> IconEntryKey {
        IconEntryKey(kind: .file, value: url.standardizedFileURL.path)
    }

    /// A link. Normalised to its absolute string; a URL that won't normalise is
    /// taken as given rather than dropped, since the caller has one either way.
    public static func url(_ url: URL) -> IconEntryKey {
        IconEntryKey(kind: .url, value: url.absoluteString)
    }

    // MARK: The lookup ladder

    /// Every key this target could be stored under, most specific first.
    ///
    /// For an application with a known location that is `[app:<path>, bundleID:<id>]`,
    /// which is `IconIdentity.lookupKeys` generalised — and it keeps the reason that
    /// ladder exists. Site-specific-browser wrappers (Coherence, Unite, the
    /// Chrome/Electron family) ship one bundle per site and every one of them reports
    /// the browser's identifier, so three wrappers keyed by identifier shared a single
    /// icon. Path first is what keeps them apart; the identifier rung is what lets an
    /// override follow an app the user moves.
    public static func lookupLadder(for target: IconTarget) -> [IconEntryKey] {
        switch target {
        case .application(let bundleURL, let bundleIdentifier):
            var ladder: [IconEntryKey] = []
            if let bundleURL { ladder.append(.app(at: bundleURL)) }
            if let bundleIdentifier { ladder.append(.app(bundleIdentifier: bundleIdentifier)) }
            return ladder
        case .file(let url):
            return [.file(at: url)]
        case .link(let url):
            return [.url(url)]
        }
    }

    /// Where a *new* override for `target` is written — the most specific key it has.
    /// `nil` for an application with neither a location nor an identifier, which is
    /// not a thing that can be overridden.
    public static func storageKey(for target: IconTarget) -> IconEntryKey? {
        lookupLadder(for: target).first
    }

    // MARK: Serialising

    /// `kind:value`, e.g. `app:/Applications/Safari.app`.
    public var serialized: String { "\(kind.rawValue):\(value)" }

    /// Parses `serialized`. Returns `nil` for an unknown kind or an empty value —
    /// both of which a hand-edited or future-version entry can produce, and neither
    /// of which should take down the load of every other entry.
    public init?(serialized: String) {
        guard let separator = serialized.firstIndex(of: ":") else { return nil }
        let rawKind = String(serialized[serialized.startIndex..<separator])
        let rawValue = String(serialized[serialized.index(after: separator)...])
        guard let kind = Kind(rawValue: rawKind), !rawValue.isEmpty else { return nil }
        self.kind = kind
        self.value = rawValue
    }

    // MARK: Naming the files on disk

    /// The base name this key's entry and image are stored under, without an
    /// extension — a sanitised stem plus a short digest of the whole serialised key.
    ///
    /// Carried over from `IconManifest.fileName(forBundleID:)`, with one deliberate
    /// change: the digest is **unconditional**. Zap appended it only when sanitising
    /// had altered the string, which kept the common case readable
    /// (`com.apple.Safari.png`) at the cost of two naming rules. With four key kinds
    /// sharing one directory, uniform names are worth more than a shorter one — and
    /// the stem still carries enough of the key to read the directory by eye.
    ///
    /// The result always satisfies `isSafeFileName(_:)` for either extension, which
    /// is what makes the directory safe to resolve against untrusted entries.
    public var fileStem: String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        // The tail is the informative part of a path — `Safari.app` beats
        // `_Applications_Utilities_`, and a long path would otherwise sanitise into
        // an unreadable run of underscores.
        let readable = (kind == .app || kind == .file)
            ? (value as NSString).lastPathComponent
            : value
        var stem = String(readable.prefix(80).map { allowed.contains($0) ? $0 : "_" })

        // Dots survive so `com.apple.Safari` reads as itself, but never as a relative
        // component, a leading dot, or a trailing one — a trailing dot would meet the
        // ".json" suffix and make a ".." that `isSafeFileName(_:)` rejects. Each pass
        // strictly shortens the string, so this terminates.
        while stem.contains("..") { stem = stem.replacingOccurrences(of: "..", with: "_") }
        while stem.hasPrefix(".") { stem.removeFirst() }
        while stem.hasSuffix(".") { stem.removeLast() }
        if stem.isEmpty { stem = "icon" }

        return "\(stem)-\(Self.shortDigest(of: serialized))"
    }

    /// A stable 32-bit FNV-1a digest, base-36.
    ///
    /// Deliberately not `hashValue`: Swift seeds that per process, so it would name
    /// the same target's icon differently on every launch — and here it would do so
    /// across three *different* processes, which is worse.
    public static func shortDigest(of string: String) -> String {
        var hash: UInt32 = 2_166_136_261
        for byte in string.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return String(hash, radix: 36)
    }

    // MARK: Path safety

    /// Whether `name` is a bare file name that cannot escape the store directory.
    ///
    /// Entries are untrusted input — a store can be hand-edited, and an imported pack
    /// arrives from someone else — and they name files the reader goes on to open.
    public static func isSafeFileName(_ name: String, extensions: Set<String>) -> Bool {
        guard !name.isEmpty, name.count <= 255 else { return false }
        guard !name.hasPrefix(".") else { return false }
        guard !name.contains("/"), !name.contains("\\"), !name.contains(":") else { return false }
        guard !name.contains("\0"), !name.contains("..") else { return false }
        guard (name as NSString).pathComponents.count == 1 else { return false }
        return extensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// Resolves `file` inside `directory`, returning `nil` unless the result really
    /// lands inside it. The name check alone is not enough: `directory` itself may
    /// contain symlinks, so the resolved paths are compared.
    public static func resolvedURL(forFile file: String, in directory: URL,
                                   extensions: Set<String>) -> URL? {
        guard isSafeFileName(file, extensions: extensions) else { return nil }
        let candidate = directory.appendingPathComponent(file)
        let resolvedDirectory = directory.standardizedFileURL.resolvingSymlinksInPath().path
        let resolvedCandidate = candidate.standardizedFileURL.resolvingSymlinksInPath().path
        guard resolvedCandidate.hasPrefix(resolvedDirectory + "/") else { return nil }
        return candidate
    }
}

/// The thing an icon is being resolved *for*, as the calling app knows it.
///
/// Separate from `IconEntryKey` on purpose: a caller has an app or a file, not a
/// storage key, and turning one into the other is this module's job rather than
/// each app's. It is also what keeps the SSB-wrapper rule in one place — an app is
/// a URL *and* an identifier, and only `lookupLadder(for:)` decides which wins.
public enum IconTarget: Hashable, Sendable {
    case application(bundleURL: URL?, bundleIdentifier: String?)
    case file(URL)
    case link(URL)

    /// The application at `bundleURL`, reading its identifier from the bundle when
    /// one is not already to hand.
    public static func application(at bundleURL: URL) -> IconTarget {
        .application(bundleURL: bundleURL,
                     bundleIdentifier: Bundle(url: bundleURL)?.bundleIdentifier)
    }
}
