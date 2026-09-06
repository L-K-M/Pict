# Linux port — implementation plan pointer

The end-to-end implementation plan for the Ubuntu port (both repos) lives in the
TopDrawer repository:
[`docs/linux-port/implementation-plan.md`](https://github.com/L-K-M/TopDrawer/blob/main/docs/linux-port/implementation-plan.md)
— with the executor prompt beside it as `implementation-prompt.md`. Its Part 0
(ground rules, PR lifecycle, steady-state and merge protocol) governs every PR in
**this** repo too.

The plan items that land here, in order:

| Item | What lands in Pict |
|---|---|
| LP-01 | Linux CI + the portable PictKit subset compiling and testing on Linux |
| LP-03 | `PixelImage` + codec seam; the artwork math on Linux |
| LP-04 | Pure-Swift raster backend (swift-png + pixel ops incl. the shadow) |
| LP-05 | `IconStore` image path on Linux + inotify `IconStoreWatcher` |
| LP-06 | Resolver/status/PictURL portable — PictKit fully compiles on Linux |
| LP-14 | `pict` CLI (store operations) |
| LP-15 | `.desktop` override sync (`pict sync-overrides`) |
| LP-24a | `ArtworkProviding` via icon-theme lookup (prerequisite for TopDrawer's LP-24b) |
| LP-32 | Debian packaging for `pict` |
| LP-33–36 | The GTK editor app: shell, SVG ingestion + local sets, remote sets + Iconify, WebKitGTK web picker |

## The Jetty port's items

[Jetty](https://github.com/L-K-M/Jetty) — the third app that reads this store — is
being ported to Ubuntu too, under its own plan
([`docs/linux-port-plan.md`](https://github.com/L-K-M/Jetty/blob/main/docs/linux-port-plan.md),
items `JP-01`…`JP-35`). Two of those items land **here**, both because a second
consumer clears `AGENTS.md`'s bar for putting something in `PictKit`:

| Item | What lands in Pict |
|---|---|
| JP-12 | `DesktopEntry` parser + `DesktopEntryIndex` in `Sources/PictKit/Store/` — the spec-correct read of `.desktop` files (XDG + snap + Flatpak dirs, ID dedupe, `NoDisplay`/`OnlyShowIn`/`TryExec`, the locale ladder, `Exec` field codes). Jetty needs it for its dock items and command bar, TopDrawer's LP-19 currently plans a private copy, and it retires `DesktopOverrideSync.overrideFilename(forSystemPath:)`'s documented best-effort desktop-ID guess |
| JP-13 | The same work as **LP-24a** above (`ArtworkProviding` via icon-theme lookup). Jetty is a second reason to land it: rung 4 of its icon ladder is `NSWorkspace.icon(forFile:)`, whose Linux analogue is exactly this lookup |

Keep JP-12 small — an entry value type, an index, and a lookup. No preferences, no
UI, no launching: it is a public surface and therefore a compatibility commitment
across three release cadences.

Background for every choice: this repo's [`linux-port.md`](linux-port.md) (the
Pict-specific research), Jetty's
[`docs/linux-port.md`](https://github.com/L-K-M/Jetty/blob/main/docs/linux-port.md),
and the TopDrawer repo's `docs/linux-port/` research set.
