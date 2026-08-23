# Porting Pict to Ubuntu Linux — Research & Plan

*Research completed 2026-08-23, from a file-by-file read of the codebase (77 files,
12,221 LOC) plus verification of the Linux ecosystem against primary sources.
Confidence markers where it matters: **[V]** verified, **[I]** inference, **[U]**
unverified. The companion research for Top Drawer — desktop-shell constraints, the
Swift-on-Linux toolchain report, and UI-framework evaluations — lives in the
TopDrawer repo under `docs/linux-port/`; this document is self-contained for Pict.*

## Framing: what a Linux Pict even is

Pict exists to undo macOS 26's squircle icon masking. **On Linux the core problem
does not exist** — no compositor masks app icons. So the port is really two
different products:

1. **PictKit as a portable shared icon store + resolution library** — genuinely close
   to portable today, and useful to any Linux app that draws its own icons (a ported
   Top Drawer drawer, a dock, a switcher). This is the part worth porting first and
   the part the TopDrawer port depends on.
2. **The Pict editor** — an app for assigning per-app icons. On Linux this gains a
   *system-wide* superpower macOS never allowed: the freedesktop stack has
   spec-blessed, update-surviving mechanisms for overriding any app's icon
   everywhere (details below). The ingestion pipeline (SVG, web picker, icon sets)
   ports with different plumbing — and the icon-set feature is *Linux-native
   content* (Papirus/Tela/Numix/Breeze/Adwaita) coming home.

## What the inventory found

Portability buckets over 7,777 source LOC (tests excluded):

| Bucket | LOC | % |
|---|---|---|
| P1 — compiles on Linux today | ~1,162 | 15% |
| P2 — Foundation-only, specific APIs to verify | ~1,221 | 16% |
| P3 — platform service behind a seam (~700 LOC of which is pure logic that survives verbatim) | ~3,153 | 41% |
| P4 — UI needing a Linux UI layer | ~2,057 | 26% |
| P5 — macOS-only concept (`BundleArtwork` and friends) | ~184 | 2% |

Highlights that port unchanged: the store engine (JSON+PNG, atomic writes,
last-writer-wins), `IconEntry`/`IconEntryKey`, `ZapManifestImport`, the whole `Sets/`
logic (name guessing, auto-match, catalogue, symlink-safe provider),
`OriginalImageResolver`/`WebImageSource`/`PickedWebImage`, `SVGRenderGate`, and the
majority of the Artwork *math* (`AlphaMask` measurements, `IconShapeClassifier`
thresholds, `IconNormalizer.layout()`, `IconImageValidator.check()`) — all already
test-proven through CG-free pure inits.

## The five seams that make PictKit compile on Linux

The code is unusually well-factored for this; none of these fight the design:

1. **Raster/codec seam** — a `PixelImage` (RGBA8 buffer + dimensions) + codec
   protocol replacing `CGImage` in `IconStore` (2 methods), `IconImageValidator`
   decode/encode, `AlphaMask.init(image:)`, `IconBitmap`, `IconNormalizer.normalize`,
   `IconShapeClassifier`'s two overloads, `IconResolver.resolve`. The measurement/
   layout/classification math moves over unchanged. Linux backend: **Cairo**
   (ARGB32 premultiplied — the same model as CG; rounded-rect clip, high-quality
   downsample) + **libpng/gdk-pixbuf** for codec. The one genuinely new piece of
   work: CG's `setShadow` has no Cairo primitive — the normalizer's baked drop
   shadow needs a small blur-from-alpha-mask implementation, and the existing
   shadow-asymmetry test verifies it for free.
2. **Display-image seam** — `IconResolver` returns `NSImage` built in exactly one
   place; make the output generic (Linux consumers want a `GdkPixbuf`/
   `cairo_surface_t`/raw buffer + scale).
3. **Watcher seam** — `IconStoreWatcher` is FSEvents top to bottom; the
   `init(directory:onChange:)`/`start`/`stop` shape is already the protocol. Linux
   impl: **inotify** on the entries directory (~100 LOC; `IN_MOVED_TO|IN_CREATE|
   IN_DELETE` covers the atomic-rename writes). Two traps the macOS code warns
   about implicitly:
   - `kFSEventStreamCreateFlagIgnoreSelf` has **no inotify equivalent** — the port
     must tag-and-filter its own writes or tolerate self-invalidations;
   - `WatchRoot` semantics: the entries dir may not exist on first run; inotify
     can't watch a nonexistent path — watch the parent until it appears.
4. **Artwork-provider seam** — rung 2 (`BundleArtwork`, the only file with no Linux
   meaning at all) behind `ArtworkProviding`. The Linux implementation resolves a
   desktop entry's `Icon=` through the freedesktop Icon Theme spec (GTK
   `GtkIconTheme` or a small spec implementation).
5. **Launcher seam** — `PictURL`'s two `NSWorkspace` calls → `xdg-mime query default
   x-scheme-handler/pict` (install-probe without launching) and `xdg-open` +
   a `.desktop` file declaring the scheme.

### Load-bearing details the port must preserve

- **Hash stability:** entry filenames use unconditional FNV-1a base36 precisely so
  four processes name the same target's files identically. Byte-identical digests
  or every existing store entry orphans.
- **`Data.write(options: .atomic)` is "the whole concurrency story."** Verified:
  Linux corelibs implements `.atomic` as write-to-temp + `rename(2)` **[V]** — the
  multi-writer guarantees carry over on ext4/xfs/btrfs.
- **`IconSourceMode.systemDefault` disables everything off-macOS**: `isSquircleJailed`
  is false on Linux → default mode `.system` → resolver returns nil for every
  target. Linux consumers must pass `.originalPlusCustom` explicitly (the `plain()`
  factory's comment documents this exact trap).
- **Main-queue delivery contracts** (`IconResolver.onIconsResolved`,
  `IconStoreWatcher.onChange`, `IconArtworkStatus.load`): a Linux daemon or GTK app
  must actually drain a main queue (`dispatchMain()` or GLib main-loop integration)
  or these silently never fire.
- **The security posture must survive the rewrite**: filename bounds-checks +
  resolved-symlink prefix comparisons (themes are full of symlinks), byte-counted
  downloads (never trust Content-Length), thumbnail-bounded decodes (a header can't
  force an allocation), everything re-encoded to PNG. None of it is macOS-specific;
  all of it is easy to lose.
- **Store identity on Linux:** `file:`/`url:` keys work unchanged; `bundleID:` maps
  naturally to desktop-file/Flatpak IDs; `app:` (a path) can carry a `.desktop`
  path — and the format already tolerates unknown kinds (skip, never fatal). The
  store lands at `$XDG_DATA_HOME/Pict` via the (verified) swift-foundation XDG
  mapping of `.applicationSupportDirectory`. Wrapper disambiguation (Flatpak vs
  snap vs native Firefox) is the SSB-wrapper problem re-skinned — the two-rung key
  ladder already models it.

## The editor, subsystem by subsystem

### SVG rasterization: delete the flagship hack

The two-render WKWebView alpha-recovery machinery (~380 LOC of window parking, CSP
jails, dual black/white passes, PDF capture) exists only because WebKit composites
onto opaque white. On Linux, **librsvg** (system library, GNOME-standard) or
**resvg** (linebender org, official C API, best-in-class static-SVG conformance)
render straight to RGBA. Port decision:

- Keep (~260 LOC, pure, already tested): `isSVG` sniffing, `scalable()` viewBox
  synthesis + the quote-aware attribute scanner — **still needed**: Papirus icons
  are `width="64"` with no viewBox under *any* renderer honoring intrinsic size.
- Re-establish the CSP *intent* (hostile SVG must not reach the network) in the new
  renderer's terms: resvg — no href resolution/resources dir; librsvg — verify its
  external-reference policy before shipping **[U]**.
- **Bump/namespace `renderVersion`** in `IconRenderCache` — switching renderers is a
  renderer-behavior change by definition, and the cache key encodes it for exactly
  this reason.

### The web picker: WebKitGTK 6.0 is a near-1:1, sometimes better

Ubuntu 24.04+ ships `webkitgtk-6.0` (2.52.x). Verified mappings **[V]**:

| WKWebView usage | WebKitGTK 6.0 |
|---|---|
| `willOpenMenu` subclass + record-then-reread race workaround | `context-menu` signal delivers `WebKitHitTestResult` **synchronously**, with `get_image_uri()` — the workaround becomes unnecessary |
| `WKUserScript` + script message handlers | `WebKitUserContentManager` + `window.webkit.messageHandlers.NAME.postMessage(...)` — the injected JS ports verbatim |
| `evaluateJavaScript` | `webkit_web_view_evaluate_javascript` (with script worlds) |
| `.nonPersistent()` data store | ephemeral `WebKitNetworkSession` |

No maintained Swift binding exists for WebKitGTK — plan direct C API use; the
[silveran-reader](https://github.com/kyonifer/silveran-reader) app has a copyable
`CWebKitGTK` systemLibrary + bridge (custom URI scheme, JS messaging, embedding).

### Networking

`IconifyClient`/`CollectionCache` use `URLSession.data(from:)` — fine via
`FoundationNetworking` (the async conveniences exist on Linux **since Swift 6.0
only**). Two spots resolved by adversarial verification against corelibs source
**[V]**:

- **`RemoteIconFetcher`:** `URLSession.bytes(for:)`/`AsyncBytes` **has never existed
  on Linux** — the symbol is simply absent, a compile error
  ([corelibs#5401](https://github.com/swiftlang/swift-corelibs-foundation/issues/5401)).
  Port to a delegate-based data task or AsyncHTTPClient, **preserving the
  count-as-you-go byte cap** — the point is not trusting Content-Length.
- **`IconSetInstaller`:** async `download(for:)` **is implemented on Linux**
  (since Swift 6.0; the temp file is not auto-removed — which this code already
  handles by moving it).
- The two test files stubbing `URLProtocol` (`IconifyClientTests`'
  `RefusingURLProtocol`, `IconSetInstallerTests`' `ArchiveURLProtocol`) **can port**,
  with one required change: inject stubs via `configuration.protocolClasses`
  (stub first) — `URLProtocol.registerClass` alone never intercepts http(s) on
  Linux because the default config's built-in HTTP protocol claims every request
  first ([corelibs#4940](https://github.com/swiftlang/swift-corelibs-foundation/issues/4940)).

### GNU tar vs BSD tar (a real, silent-data-loss-shaped bug)

`IconSetInstaller` hardcodes `/usr/bin/tar` with trailing pattern args — bsdtar
treats trailing args as patterns by default; **GNU tar requires `--wildcards`** and
differs on no-match exit behavior (a test comment depends on bsdtar's refusal).
Ubuntu ships GNU tar. Pass `--wildcards` on Linux (or use libarchive), and port
`IconSetInstallerTests` first — they hit the divergence directly. On Linux the sets
feature can additionally source *locally installed* system themes
(`/usr/share/icons`) with zero downloading — a strictly easier problem than the one
the code already solves.

### App enumeration + system icons (`InstalledApps`, `IconTargetRow`)

The directory-walk-and-dedupe pattern survives; the content changes: enumerate
desktop entries via `g_app_info_get_all()` across `$XDG_DATA_DIRS/applications`
(dedupe by desktop-file ID, honor `NoDisplay`), which on Ubuntu includes snap
(`/var/lib/snapd/desktop/applications` — note snapd rewrites `Icon=` to absolute
`${SNAP}` paths) and Flatpak export dirs (icons named by app ID in exported
hicolor). System icon lookup = `GtkIconTheme` resolution instead of
`NSWorkspace.icon(forFile:)`.

### Applying icons system-wide (the Linux-only superpower)

Two spec-blessed mechanisms, both "just files":

1. **Per-app `.desktop` shadowing (recommended primary):** copy the entry to
   `~/.local/share/applications/<same-id>.desktop` with `Icon=` changed (absolute
   path allowed by the spec). `$XDG_DATA_HOME` wins the ID resolution, GNOME
   Shell's dash/switcher honor it, and it **survives app updates** (unlike macOS
   `Icon\r` hacks). One care point: don't fork stale copies — regenerate overrides
   (original entry + only `Icon=` replaced) whenever the system entry changes; the
   ported `IconStoreWatcher` plus a watch on the system dirs makes Pict the daemon
   that keeps these in sync.
2. **Icon-theme route:** a generated user theme (`~/.local/share/icons/Pict/` +
   `index.theme` inheriting the active theme) for theme-wide overrides — more
   powerful, more fragile across theme switches (Yaru ships branded icons that
   outrank hicolor). Offer as the "everywhere, including the shell grid" option.

The JSON+PNG store stays the source of truth in both cases; consumers like a ported
Top Drawer read it directly (draw-time substitution), everything else gets it via
the override files. **This turns Pict from a workaround into a first-class desktop
customization tool on Linux.**

### The editor UI

SwiftUI views (~2,057 LOC) are rewritten against a GTK stack — see the TopDrawer
repo's `docs/linux-port/04-ui-frameworks.md` for the full evaluation. Short version:
**SwiftCrossUI (GTK4 backend) or Adwaita for Swift** for the windows/lists/sheets,
plus small C-interop pieces for the two things neither wraps today (file DnD onto
rows, the WebKitGTK view). `IconEditorModel` is deliberately view-free except
`NSOpenPanel`/`NSImage` — extract those two and the orchestration ports.
`IconProblem`'s titles/messages are pure data and port as-is.

## Sandboxing posture

The PictKit/App split exists so image parsing, the web view, and the `tar`
subprocess never enter the consumers (Zap holds an Accessibility tap on macOS). The
Linux equivalent concern: keep the *store* readable by plain processes, and consider
running the editor's ingestion under a tighter sandbox eventually — but do **not**
Flatpak the editor naively: its whole purpose is writing
`~/.local/share/applications` and icons on the host, which would need
`--filesystem` holes that defeat the sandbox. A `.deb` (plus the store spec'd as
plain files) is the honest packaging; a `pict` CLI (fetch/convert/assign icons) is
a natural early deliverable and is fully buildable with the static Linux SDK.

## Test suite

~1,450 LOC of tests run unmodified on Linux today (pure Foundation suites:
entry keys, Zap import, name guessing, auto-match, web pick/source, render gate,
catalogue, provider symlink safety). Another ~1,800 LOC port mechanically once the
raster-seam fixture (`IconTestSupport.makeImage`/`writePNG`) is re-implemented once
per suite — including `IconStoreTests` (multi-writer/hostile-entry suite — the most
valuable porting asset in the repo) and the classifier/normalizer/validator math.
`AGENTS.md` already draws exactly the boundary a port needs ("FSEvents delivery,
WKWebView rasterisation … cannot be covered in CI"). Port
`testInkAtTheTopOfThePageLandsAtTheTopOfTheBitmap`-style orientation fixtures with
any new backend — they are the only tests that catch a flipped coordinate
convention.

## Suggested sequence

1. **CI first:** add a Linux job (`swift:6.3` container) running the already-pure
   test subset. Zero risk, immediate regression net.
2. **Seams 1–5** behind `#if canImport(CoreGraphics)` / protocols, keeping the macOS
   build byte-identical in behavior; land the Cairo/libpng backend with the ported
   math tests.
3. **`pict` CLI on Linux** (store read/write, theme import, `.desktop` override
   sync) — proves the store + artwork stack end-to-end without any UI framework
   bet, and gives the TopDrawer daemon its icon source.
4. **Editor app**: GTK shell, WebKitGTK picker (silveran pattern), resvg/librsvg
   ingestion, sets from local system themes first (no networking needed for v1).

Estimated shareable code: **~55–70% of app LOC** plus effectively all of PictKit;
the rewrite surface is the ~2k LOC of SwiftUI views and ~640 LOC of rasterizer
machinery that gets *deleted* rather than ported.
