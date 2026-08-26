import ArgumentParser
import Foundation
import PictKit
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// `pict` — store operations from a terminal (LP-14).
///
/// A thin front end over PictKit's `IconStore`: the same shared directory Pict, Zap,
/// Jetty and Top Drawer read, on Linux (`$XDG_DATA_HOME/Pict`) and macOS
/// (`~/Library/Application Support/Pict`) alike.
@main
struct PictCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pict",
        abstract: "Read and write the shared Pict icon store.",
        subcommands: [List.self, Get.self, SetCommand.self, Remove.self, PathCommand.self,
                      SyncOverridesCommand.self]
    )
}

// MARK: - Shared options

/// Which store directory to operate on. Defaults to the shared platform location, so a
/// bare `pict …` acts on the same store the apps do; `--store` points it elsewhere (a
/// second profile, or a temp directory under test).
struct StoreOptions: ParsableArguments {
    @Option(name: .long, help: "The icon store directory. Defaults to the shared location.")
    var store: String?

    /// The resolved store directory, without loading it.
    var directory: URL {
        if let store {
            // Expand a leading `~` (a quoted `--store ~/AltStore` the shell left intact),
            // so a scripted secondary-profile path targets the real home directory.
            return URL(fileURLWithPath: (store as NSString).expandingTildeInPath, isDirectory: true)
        }
        return IconStoreLocation.defaultDirectory()
    }

    /// Opens (and indexes) the store.
    func makeStore() -> IconStore {
        IconStore(directory: directory)
    }
}

/// A runtime failure with a message fit to print. Conforms to both `CustomStringConvertible`
/// and `LocalizedError` so ArgumentParser surfaces the message however it renders errors.
struct RuntimeError: Error, CustomStringConvertible, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
    var errorDescription: String? { message }
}

/// Resolves a key argument to the store's own canonical key, or throws a usage error
/// naming the accepted forms.
///
/// Canonicalizing here — not just in `set` — is what keeps `set`, `get` and `remove`
/// agreeing. `IconStore.setIcon` derives its storage key via `storageKey(for:)`, which
/// standardizes paths (a relative `.desktop` path like `firefox.desktop` becomes
/// cwd-absolute) and normalizes URL strings. If `get`/`remove` looked up the typed key
/// verbatim, a `set firefox.desktop` would land under `app:/cwd/firefox.desktop` while
/// `get firefox.desktop` looked for `app:firefox.desktop` and found nothing. Resolving
/// through `storageKey(for: key.asTarget)` makes every subcommand share that derivation;
/// it is idempotent on the already-canonical keys `pict list` prints.
func resolveKey(_ argument: String) throws -> IconEntryKey {
    switch KeyArgument.key(from: argument) {
    case .success(let key):
        return IconEntryKey.storageKey(for: key.asTarget) ?? key
    case .failure(let failure):
        throw ValidationError(failure.description)
    }
}

// MARK: - list

struct List: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List every icon override in the store.")

    @OptionGroup var options: StoreOptions

    func run() throws {
        let store = options.makeStore()
        // Deterministic order (by serialized key) so the output is stable for scripts
        // and the integration test.
        for key in store.entries.keys.sorted(by: { $0.serialized < $1.serialized }) {
            guard let entry = store.entry(for: key) else { continue }
            // target <TAB> source <TAB> image — the target (key), where it came from
            // (origin), and the stored PNG name (or "-" for a system pin).
            print("\(key.serialized)\t\(entry.origin.rawValue)\t\(entry.image ?? "-")")
        }
    }
}

// MARK: - get

struct Get: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show the store entry for a key.")

    @OptionGroup var options: StoreOptions
    @Argument(help: "app:…, bundleID:…, file:…, url:…, or a .desktop path (relative paths resolve against the current directory).") var key: String

    func run() throws {
        let entryKey = try resolveKey(key)
        let store = options.makeStore()
        guard let entry = store.entry(for: entryKey) else {
            throw RuntimeError("No entry for \(entryKey.serialized).")
        }

        print("key:      \(entryKey.serialized)")
        print("origin:   \(entry.origin.rawValue)")
        if let image = entry.image {
            print("image:    \(image)")
            print("path:     \(store.entriesDirectory.appendingPathComponent(image).path)")
        }
        if let writtenBy = entry.writtenBy { print("writtenBy: \(writtenBy)") }
        if let provider = entry.provider { print("provider: \(provider)") }
        if let addedAt = entry.addedAt {
            print("addedAt:  \(ISO8601DateFormatter().string(from: addedAt))")
        }
    }
}

// MARK: - set

struct SetCommand: ParsableCommand {
    // Named `SetCommand`, not `Set`, so it doesn't shadow `Swift.Set` module-wide (the
    // test target `@testable import`s this module). `commandName` keeps the CLI `pict set`.
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Set the icon for a key from an image file.",
        discussion: "The image is validated and re-encoded into the store as PNG. On "
            + "Linux the source must be a PNG; on macOS any raster format ImageIO reads "
            + "is accepted."
    )

    @OptionGroup var options: StoreOptions
    @Argument(help: "app:…, bundleID:…, file:…, url:…, or a .desktop path (relative paths resolve against the current directory).") var key: String
    @Argument(help: "Path to the source image.") var imageFile: String

    func run() throws {
        let entryKey = try resolveKey(key)
        // Expand a leading `~` like `--store` and the key paths do, so the three path
        // inputs handle a quoted/scripted tilde consistently.
        let url = URL(fileURLWithPath: (imageFile as NSString).expandingTildeInPath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw RuntimeError("No such image file: \(imageFile)")
        }
        // Reject a directory with its own message rather than let it fall into decode and
        // die with a misleading "couldn't decode as PNG" — a common tab-completion mistake.
        guard !isDirectory.boolValue else {
            throw RuntimeError("'\(imageFile)' is a directory, not an image file.")
        }

        let store = options.makeStore()
        let target = entryKey.asTarget

        let result: Result<IconEntry, IconStore.WriteFailure>
        #if canImport(CoreGraphics)
        switch IconImageValidator.decode(contentsOf: url) {
        case .success(let image):
            result = store.setIcon(image, for: target, writtenBy: "pict")
        case .failure(let rejection):
            throw RuntimeError(rejection.message)
        }
        #elseif os(Linux)
        guard let image = LinuxImageDecoding.decodePNG(contentsOf: url) else {
            // The Linux codec returns nil both for a corrupt/non-PNG file and for one
            // whose dimensions exceed the store's limits, so name both possibilities.
            throw RuntimeError("Couldn't decode '\(imageFile)' as a PNG, or it exceeds the store's size limits.")
        }
        // Apply the accept gate the macOS ImageIO decode runs for free (minimum size,
        // aspect ratio); the Linux codec only bounds the maximum.
        if case .failure(let rejection) = IconImageValidator.check(pixelWidth: image.width,
                                                                   pixelHeight: image.height) {
            throw RuntimeError(rejection.message)
        }
        result = store.setIcon(image, for: target, writtenBy: "pict")
        #else
        // The two decode branches are aligned with their backends (CoreGraphics on macOS,
        // LinuxImageDecoding on Linux) rather than assumed complements. A third platform
        // needs its own decode path; fail loudly instead of a cryptic missing-symbol error.
        #error("pict set has no image decode path for this platform")
        #endif

        switch result {
        case .success(let entry):
            if let image = entry.image {
                print("Set \(entryKey.serialized) → \(store.entriesDirectory.appendingPathComponent(image).path)")
            } else {
                print("Set \(entryKey.serialized)")
            }
        case .failure(let failure):
            throw RuntimeError(message(for: failure))
        }
    }

    private func message(for failure: IconStore.WriteFailure) -> String {
        switch failure {
        case .rejected(let rejection): return rejection.message
        case .directoryUnavailable: return "Couldn't write to the store directory."
        case .unkeyable: return "That key can't be stored under."
        }
    }
}

// MARK: - remove

struct Remove: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Remove the icon override for a key.")

    @OptionGroup var options: StoreOptions
    @Argument(help: "app:…, bundleID:…, file:…, url:…, or a .desktop path (relative paths resolve against the current directory).") var key: String

    func run() throws {
        let entryKey = try resolveKey(key)
        let store = options.makeStore()
        guard store.entry(for: entryKey) != nil else {
            throw RuntimeError("No entry for \(entryKey.serialized).")
        }
        store.clear(for: entryKey)
        print("Removed \(entryKey.serialized)")
    }
}

// MARK: - path

struct PathCommand: ParsableCommand {
    // Named `PathCommand`, not `Path`, to avoid shadowing Foundation's `Path`.
    static let configuration = CommandConfiguration(commandName: "path",
                                                    abstract: "Print the store directory.")

    @OptionGroup var options: StoreOptions

    func run() throws {
        print(options.directory.path)
    }
}
