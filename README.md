# Pict

**One icon change, everywhere.** Pict is the shared icon store behind
[Zap](https://github.com/L-K-M/Zap) (a ⌘-Tab switcher),
[Jetty](https://github.com/L-K-M/Jetty) (a Dock replacement) and
[Top Drawer](https://github.com/L-K-M/TopDrawer) (an edge-tab launcher) — and the
editor that fills it.

Give Safari a custom icon once and all three apps draw it.

> [!IMPORTANT]
> LLM Disclosure: this code base was written by or with the help of large language
> models, working from the [`AGENTS.md`](AGENTS.md) brief in this repo.

> [!WARNING]
> **Work in progress, and not yet compiled.** `PictKit` is written but has never
> been through a Swift toolchain — it was authored in an environment without one.
> Expect a first build to turn up real errors. The Pict app itself is not built yet.
> See [Status](#status).

## Why this exists

Since macOS 26 (Tahoe) the system composites every app icon into one fixed
superellipse. Artwork that predates Tahoe gets scaled down onto a grey plate and
masked — the whole back catalogue of Mac icons, flattened.

Zap, Jetty and Top Drawer all draw their own icons, so none of them is obliged to
show the masked version. Zap already doesn't. The problem was that its fix lived
entirely inside Zap: change an icon there and Jetty's dock still showed the
system's.

Pict is that fix, moved somewhere all three can reach.

The full research and the reasoning behind this design is in Zap's
[`SHARED-ICONS.md`](https://github.com/L-K-M/Zap/blob/main/SHARED-ICONS.md).

## What's in here

This repository is **two things**, which is why the layout looks unusual:

```
Package.swift          ← the repo root is a SwiftPM package
Sources/PictKit/         the read path, consumed by Zap, Jetty, Top Drawer and Pict
Tests/PictKitTests/
App/                     the Pict app — the editor, and everything only it needs
```

`Package.swift` has to be at the repo root because SwiftPM cannot depend on a
subdirectory of a repository. The app lives under `App/` and references the package
locally; the three other apps reference it remotely.

### PictKit — the read path

Small and boring on purpose: three independently released apps are pinned to it, so
the less it changes the better.

| | |
|---|---|
| `Store/` | the shared store — keys, entries, reading, writing, watching |
| `Artwork/` | recovering a bundle's own artwork, classifying its shape, normalising it |
| `Resolve/` | the resolution ladder and its cache; the only thing a hot path touches |
| `Migration/` | carrying Zap's existing icons into the shared store, once |

### Pict — the editor

Everything with exactly one consumer: picking and validating a file, rasterising
SVG, downloading icon themes, searching providers, and the UI for all of it.

Deliberately **not** in the package. Those parts are also the parts that decode
untrusted images, stand up a `WKWebView` and spawn a subprocess — and Pict is the
only one of the four apps that needs no Accessibility permission, so it is the only
one that could ever be sandboxed. Keeping them here keeps them out of the app that
holds the event tap.

## The store

```
~/Library/Application Support/Pict/
  README.txt
  entries/
    Safari.app-1k2j4h.json
    Safari.app-1k2j4h.png
```

**One file per entry, not one manifest.** Three processes read-modify-writing a
single `manifest.json` will lose entries. Splitting it removes the problem rather
than managing it: two apps overriding two different targets touch two different
files and cannot conflict, two apps overriding the same one resolve by
last-writer-wins, every write is atomic, and the directory listing *is* the index.

Deleting the folder is always safe — every app falls back to the icons macOS
provides.

## Status

| | |
|---|---|
| `PictKit` store, resolver, artwork, migration | written, **not compiled** |
| `PictKitTests` | written, **not run** |
| Pict app (editor, ingestion, themes, search) | not started |
| Zap / Jetty / Top Drawer wired to `PictKit` | not started |

Nothing here has been near a Mac yet. The three consuming apps are unchanged and
keep working exactly as they do today.

## Build

```bash
swift build
swift test
```

Requires macOS 13+ and a Swift 5.9 toolchain.

## License

Public domain — see [LICENSE](LICENSE).
