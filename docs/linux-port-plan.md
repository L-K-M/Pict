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

Background for every choice: this repo's [`linux-port.md`](linux-port.md) (the
Pict-specific research) and the TopDrawer repo's `docs/linux-port/` research set.
