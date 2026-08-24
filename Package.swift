// swift-tools-version: 5.9
import PackageDescription

/// `PictKit` is the **read path**: everything Zap, Jetty and Top Drawer need to
/// turn a thing on disk into the picture to draw for it, plus the shared store
/// that holds the user's choices.
///
/// Deliberately *not* here: ingestion, icon themes, provider search and the
/// editing UI. Those have exactly one consumer — the Pict app in `App/` — so they
/// live there rather than in a library three apps have to carry. See `PLAN.md §2`.
// On Linux, PictKit is ported behind protocol seams one PR at a time (see
// `docs/linux-port.md`). Until the whole target compiles on Linux, curate the
// files that already do with a `sources:` list — SwiftPM compiles only the listed
// files (it warns that the rest of the target directory is "unhandled"; that list
// shrinks to nothing as the port lands and is expected here). `#if os(Linux)` in
// the manifest is evaluated on the build host, so macOS keeps building the entire
// target (a `nil` `sources:` means "compile everything") and its behaviour is
// untouched. Caveat: this is host-keyed, not target-keyed — a macOS→Linux
// cross-compile (e.g. the static Linux SDK) also runs the manifest on macOS,
// takes the `nil` path, and would try to compile the not-yet-ported files for
// Linux. Build the Linux target natively (the container CI) until the port lands.
#if os(Linux)
let pictKitSources: [String]? = [
    "Store/IconEntry.swift",
    "Store/IconEntryKey.swift",
    "Store/IconStoreLocation.swift",
    "Store/IconStore.swift",
    "Migration/ZapManifestImport.swift",
    "Resolve/IconSourceMode.swift",
    // LP-03: the artwork seam + pure math (CG-touching members guarded).
    "Artwork/PixelImage.swift",
    "Artwork/AlphaMask.swift",
    "Artwork/IconShapeClassifier.swift",
    "Artwork/IconNormalizer.swift",
    "Artwork/IconImageValidator.swift",
    "Artwork/IconBitmap.swift",
    "Resolve/IconRenderOptions.swift",
    // LP-04: pure-Swift raster backend + the Linux PNG codec (swift-png).
    "Artwork/PixelImageOps.swift",
    "Artwork/LinuxCodec.swift",
    // LP-05: the store's image path on Linux + the inotify store watcher. The
    // FSEvents file compiles to nothing here (whole-body `#if canImport(CoreServices)`).
    "Store/IconStoreWatcher.swift",
    "Store/IconStoreWatcherLinux.swift",
]
let pictKitTestsSources: [String]? = [
    "IconEntryKeyTests.swift",
    "ZapManifestImportTests.swift",
    // LP-03: pure-subset suites (CG-dependent methods guarded within each file).
    "ResultConveniences.swift",
    "PixelImageTests.swift",
    "IconBitmapTests.swift",
    "IconShapeClassifierTests.swift",
    "IconNormalizerTests.swift",
    "IconImageValidatorTests.swift",
    // LP-04: the raster backend fixtures + render/codec suites.
    "IconTestSupport.swift",
    "PixelImageRenderTests.swift",
    "PixelImageCodecTests.swift",
    // LP-05: the store on Linux (PixelImage fixture) + the inotify watcher.
    "IconStoreTests.swift",
    "IconStoreWatcherTests.swift",
]
#else
let pictKitSources: [String]? = nil
let pictKitTestsSources: [String]? = nil
#endif

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
