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
    targets: [
        .target(name: "PictKit", sources: pictKitSources),
        .testTarget(name: "PictKitTests", dependencies: ["PictKit"],
                    sources: pictKitTestsSources)
    ]
)
