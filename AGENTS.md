# AGENTS.md

Guidance for AI coding agents working in the **Pict** repository.

## What Pict Is

The shared icon store behind Zap, Jetty and Top Drawer, and the editor that fills
it. Set an icon once; all three apps draw it.

`PictKit` (repo root) is the library those apps link. `App/` is the Pict editor.
The design and the reasoning behind it live in Zap's `SHARED-ICONS.md`.

## Tech Stack

- **Language:** Swift (latest stable), Swift 5.9 tools version.
- **Library:** Foundation, CoreGraphics, ImageIO, CoreServices (FSEvents), AppKit
  only where an `NSImage` has to cross the boundary.
- **App:** SwiftUI for the editor, AppKit for windowing.
- **Min target:** macOS 13 (Ventura) — matches all three consuming apps.
- **Persistence:** a directory of JSON + PNG pairs in Application Support. Not
  `UserDefaults`, which is a plist read in full at launch; image blobs don't belong
  in it.

## Build & Test

The package:

```bash
swift build
swift test
```

The app — note the project is under `App/`, not at the repo root (the root belongs
to `Package.swift`, because a remote SwiftPM package must declare its manifest there):

```bash
xcodebuild -project App/Pict.xcodeproj -scheme Pict \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
```

Both suites matter and neither subsumes the other: building the app compiles
`PictKit` but does not run `PictKitTests`, which is the half three other apps
depend on. CI runs them as two jobs for that reason — see [`CICD.md`](CICD.md).

`scripts/build.sh` and `scripts/release.sh` are thin stubs over the shared
[release-tool](https://github.com/L-K-M/release-tool) engine, as in Zap, Jetty and
Top Drawer. Releases are cut by tagging: `scripts/release.sh X.Y.Z --push`.

## The Two Halves, and Why

**`PictKit` is the read path only.** Three independently released apps are pinned
to it. Every type added here is a compatibility commitment across three release
cadences, so the bar for putting something in it is that *more than one app needs
it*.

**Everything with one consumer belongs in `App/`.** Ingestion, SVG rasterisation,
theme downloads, provider search, the editor UI. This is not tidiness: those are
the parts that decode untrusted images, run a `WKWebView` and spawn a subprocess,
and keeping them out of `PictKit` keeps them out of Zap, which holds an
Accessibility event tap and can never be sandboxed. Pict can be.

## Critical Constraints

- **The store format is a contract between apps that ship separately.** An old
  build will meet entries written by a new one. So: every entry field is optional,
  decoding is lenient, an unreadable entry is skipped rather than failing the load,
  and **a reader never rewrites an entry it does not fully understand**
  (`IconEntry.isFullyUnderstood`). Adding an optional field is safe; removing or
  repurposing one is a version bump.
- **Never reintroduce a single manifest.** One file per entry is what makes three
  writers safe without a lock. See `IconStore`'s header.
- **Writes are atomic**, always — `Data.write(options: .atomic)`. A reader in
  another process must never see half a file.
- **Entries are untrusted input.** A store can be hand-edited and an imported pack
  comes from a stranger. Every file name is bounds-checked against the entries
  directory (`IconEntryKey.resolvedURL`), every number clamped, every unparseable
  enum defaulted.
- **Keep the resolver's hot path a dictionary lookup.** Zap calls `icon(for:)` once
  per app per ⌘-Tab. Anything expensive happens on the background queue, and a miss
  returns `nil` (meaning "use the system icon") rather than blocking.
- **The package must not depend on any one app's settings.** `IconRenderOptions` is
  the seam; each app maps its own preferences onto it. Don't add a `Preferences`
  type here.
- **Don't add third-party dependencies.** Prefer system frameworks.

## Conventions

- Standard Swift API Design Guidelines.
- One type per file; file name matches the primary type.
- `// MARK:` to organise sections.
- Everything in `PictKit` that an app touches must be `public` — including explicit
  `public init`s on public structs, since memberwise initialisers are internal.
- Avoid force-unwraps outside tests.
- Comments explain *why*, especially where a decision looks arbitrary. Most of the
  non-obvious choices here are load-bearing and were expensive to work out.

## Testing Notes

- The store, the keys and the migration are pure logic over a temp directory —
  unit-test them properly, including the multi-writer cases.
- Shape classification and normalisation are arithmetic over synthetic bitmaps, so
  they need no GUI session.
- FSEvents delivery, `WKWebView` rasterisation and anything Tahoe-specific need a
  real macOS session and cannot be covered in CI.

## Do / Don't

- **Do** keep `PictKit`'s public surface small; it is three apps' dependency.
- **Do** update the READMEs when the layout or the store format changes.
- **Don't** put UI in `PictKit`.
- **Don't** let the app's ingestion code become a second door into the store —
  `IconStore.setIcon` takes an image, never a URL, on purpose.
- **Don't** commit signing credentials or provisioning profiles.
