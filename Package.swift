// swift-tools-version: 5.9
import PackageDescription

/// `PictKit` is the **read path**: everything Zap, Jetty and Top Drawer need to
/// turn a thing on disk into the picture to draw for it, plus the shared store
/// that holds the user's choices.
///
/// Deliberately *not* here: ingestion, icon themes, provider search and the
/// editing UI. Those have exactly one consumer — the Pict app in `App/` — so they
/// live there rather than in a library three apps have to carry. See `PLAN.md §2`.
let package = Package(
    name: "PictKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "PictKit", targets: ["PictKit"])
    ],
    targets: [
        .target(name: "PictKit"),
        .testTarget(name: "PictKitTests", dependencies: ["PictKit"])
    ]
)
