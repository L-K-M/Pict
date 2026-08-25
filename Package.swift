// swift-tools-version: 5.9
import PackageDescription

/// `PictKit` is the **read path**: everything Zap, Jetty and Top Drawer need to
/// turn a thing on disk into the picture to draw for it, plus the shared store
/// that holds the user's choices.
///
/// Deliberately *not* here: ingestion, icon themes, provider search and the
/// editing UI. Those have exactly one consumer — the Pict app in `App/` — so they
/// live there rather than in a library three apps have to carry. See `PLAN.md §2`.
// PictKit was ported to Linux behind protocol seams one PR at a time (see
// `docs/linux-port.md`), curated with a `sources:` list while the port was partial.
// From LP-06 on, the **whole** target compiles on Linux: the files that are macOS-only
// carry whole-file `#if canImport(AppKit)` / `#if canImport(CoreServices)` guards, so
// no curation is needed. `nil` means "compile everything" on both platforms, and the
// macOS/Xcode build is unchanged. The Linux-only bits (swift-png, the CInotify shim)
// stay gated in the target graph below, not by file list.
let pictKitSources: [String]? = nil
let pictKitTestsSources: [String]? = nil

let package = Package(
    name: "PictKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "PictKit", targets: ["PictKit"])
    ],
    dependencies: [
        // The Linux PNG codec (LP-04). Pure Swift, no zlib/C deps. SwiftPM resolves the
        // repo on every platform (it lands in Package.resolved regardless — .package(url:)
        // can't be platform-conditioned), but the product condition below limits *linking*
        // to Linux, so the Xcode build never compiles it and macOS keeps decoding/encoding
        // through ImageIO in IconImageValidator.
        .package(url: "https://github.com/tayloraswift/swift-png.git", from: "4.5.0"),
    ],
    targets: [
        .target(
            name: "PictKit",
            dependencies: [
                .product(name: "PNG", package: "swift-png", condition: .when(platforms: [.linux])),
                // The inotify shim for IconStoreWatcher (LP-05). Linux-only, so the
                // Xcode/macOS build never pulls it into the graph and never sees
                // <sys/inotify.h>; the FSEvents watcher stays the macOS implementation.
                .target(name: "CInotify", condition: .when(platforms: [.linux])),
            ],
            sources: pictKitSources
        ),
        // A system-library shim exposing the inotify(7) syscalls (LP-05). Header-only:
        // the IN_* masks are hard-coded Swift-side and the event struct is parsed by
        // hand (see docs/linux-port §Part 10).
        .systemLibrary(name: "CInotify", path: "Sources/CInotify"),
        .testTarget(name: "PictKitTests", dependencies: ["PictKit"],
                    sources: pictKitTestsSources)
    ]
)
