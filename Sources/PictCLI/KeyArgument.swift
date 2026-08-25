import Foundation
import PictKit

/// Turns a command-line key argument into an `IconEntryKey`.
///
/// This is the CLI's one piece of non-trivial argument→action mapping, so it is a pure
/// function returning a `Result` — unit-testable without a store or a filesystem.
///
/// Accepted forms:
/// - The store's serialized forms verbatim — `app:…`, `bundleID:…`, `file:…`, `url:…` —
///   which are exactly the strings `pict list` prints, so a key round-trips from `list`
///   into `get` / `set` / `remove` unchanged.
/// - A bare `.desktop` file path (`/usr/share/applications/firefox.desktop`,
///   `firefox.desktop`), the Linux spelling of "an application", stored under the `app:`
///   kind — per the LP-14 plan.
enum KeyArgument {

    /// Why a key argument couldn't be turned into a key. `Equatable` so tests can assert
    /// the exact reason.
    enum Failure: Error, Equatable, CustomStringConvertible, LocalizedError {
        case empty
        case unrecognized(String)

        var description: String {
            switch self {
            case .empty:
                return "Empty key. Expected app:…, bundleID:…, file:…, url:…, or a .desktop path."
            case .unrecognized(let argument):
                return "Unrecognized key '\(argument)'. Expected app:…, bundleID:…, file:…, url:…, "
                    + "or a path ending in .desktop."
            }
        }

        var errorDescription: String? { description }
    }

    static func key(from argument: String) -> Result<IconEntryKey, Failure> {
        let trimmed = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }

        // A recognized `kind:value` wins first, so `bundleID:com.foo.desktop` stays a
        // bundle identifier rather than being mistaken for a desktop-file path.
        if let key = IconEntryKey(serialized: trimmed) { return .success(key) }

        // A bare `.desktop` path has no `kind:` prefix; it is the app's Linux location.
        // Exclude anything with a URI scheme prefix (`scheme:` at the start) — `https://…`,
        // the typo `https:/…`, `data:…` are links, not desktop-entry paths, and would make
        // a bogus `app:` key no app can match; a link belongs under an explicit `url:` key.
        // An anchored scheme check is exact where `contains("://")` both under- and
        // over-matches (it misses `data:` and rejects a path with `://` mid-string).
        if trimmed.lowercased().hasSuffix(".desktop"),
           trimmed.range(of: #"^[A-Za-z][A-Za-z0-9+.\-]*:"#, options: .regularExpression) == nil {
            return .success(IconEntryKey(kind: .app, value: trimmed))
        }

        return .failure(.unrecognized(trimmed))
    }
}

extension IconEntryKey {

    /// The `IconTarget` whose most-specific storage key is exactly this key.
    ///
    /// `IconStore.setIcon` is written for a live target and derives the key itself; the
    /// CLI is instead handed a key, so this inverts the mapping. Path-valued kinds go
    /// through the store's usual standardization (`storageKey(for:)` calls
    /// `standardizedFileURL`), which is a no-op for the absolute, already-clean paths
    /// `list` prints — so a `set` under a key from `list` lands back on that same key.
    var asTarget: IconTarget {
        switch kind {
        case .app:
            return .application(bundleURL: URL(fileURLWithPath: value), bundleIdentifier: nil)
        case .bundleID:
            return .application(bundleURL: nil, bundleIdentifier: value)
        case .file:
            return .file(URL(fileURLWithPath: value))
        case .url:
            // A stored link key is a normalized absolute URL string; fall back to a file
            // URL only if it somehow won't parse, so `asTarget` is always total.
            return .link(URL(string: value) ?? URL(fileURLWithPath: value))
        }
    }
}
