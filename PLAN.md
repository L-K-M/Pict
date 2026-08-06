# PLAN — Pict

The design, and the reasons behind the parts that look arbitrary. The research this
came out of is Zap's
[`SHARED-ICONS.md`](https://github.com/L-K-M/Zap/blob/main/SHARED-ICONS.md); this
document is the decisions, not the survey.

---

## 1. What Pict is

Three apps draw app icons — Zap's switcher, Jetty's dock, Top Drawer's drawers —
and on macOS 26 all three get the same squircle-masked composite from
`NSWorkspace`. Two of them let the user change an icon, each in its own private
store, so a change made in one is invisible to the others.

Pict is one store all four read, plus the editor that fills it.

**Zap keeps its icon feature working with no editor installed.** Recovering a
bundle's own unmasked artwork needs no user action and no UI, and that is the fix
for most apps. What a Zap-only user gives up is choosing a *file* — which Zap's own
`UNJAILED.md §10` already calls optional polish on a problem already solved.

---

## 2. Two halves

| | lives in | why |
|---|---|---|
| Store, resolution, artwork recovery, normalisation | `PictKit` | four consumers |
| Ingestion, SVG, themes, provider search, all UI | `App/` | one consumer |

The split is not tidiness. The right-hand column is also where the untrusted work
happens: decoding images from the internet, running a `WKWebView` over fetched
markup, spawning `tar`. Zap holds an Accessibility event tap and can never be
sandboxed; Pict needs no permissions at all and could be. Putting ingestion in the
library would push all of it back into the app that must not have it.

It also collapses the integration work. Jetty and Top Drawer do not port an editor —
they add one rung to their icon ladder and one menu item that opens a URL.

---

## 3. The store is a directory, not a manifest

```
~/Library/Application Support/Pict/
  README.txt
  entries/
    Safari.app-1k2j4h.json
    Safari.app-1k2j4h.png
```

A single `manifest.json` is a single-writer design. Three processes
read-modify-writing one will lose entries: Zap reads it, Pict writes it, Zap writes
its stale copy back. `NSFileCoordinator` would fix that and would put a coordination
protocol on every read on a path that has to stay cheap.

One file per entry removes the problem instead:

- Two apps overriding two different targets touch two different files — **no
  conflict is possible**.
- Two apps overriding the same target resolve by last-writer-wins, which is the
  correct semantics for "the user set this icon" and needs no lock to be right.
- Every write is `Data.write(options: .atomic)` — a temp file and a rename — so no
  reader ever sees a partial file.
- **The directory listing is the index.** There is no index to keep in step.

A half-finished delete leaves a JSON whose PNG is gone. That fails validation and
the resolver falls through to the next rung, which is exactly right.

The name is a sanitised stem plus an unconditional FNV-1a digest of the whole key —
readable by eye, unique across keys that sanitise alike, and never `hashValue`,
which Swift seeds per process and would name one target's files differently in each
of the four apps.

### 3.1 A format three apps release against

An old build will meet entries written by a new one. The rules that make that
survivable, all enforced in `IconEntry` and `IconStore`:

- every field optional, decoding lenient, unknown origins default rather than fail;
- one unreadable entry is skipped, never fatal to the load;
- **a reader never rewrites an entry it does not fully understand**
  (`isFullyUnderstood`) — that is how a newer build's fields get silently dropped.
  A *user action* still wins, because setting an icon replaces an entry outright
  rather than editing it.

Jetty's `DockStore` already does the equivalent for `dock.json` — going read-only
for the session when it meets a newer version, and saying so in the log. Same
discipline, copied rather than reinvented.

---

## 4. What a stored icon is

A PNG that Pict encoded. Not the file the user picked.

The chosen file is decoded, bounded, converted and re-encoded, so what lands on
disk is the app's own output: the original container, its EXIF, its ICC oddities and
any format-specific payload never persist. `IconStore` only accepts a `CGImage` for
that reason — a convenience overload taking a URL would be a second ingestion path
that skipped validation and silently refused every SVG, which is a bug Zap already
shipped once.

It also means an entry survives the user moving or deleting the image they picked.
Jetty's current per-item override stores a raw path and does not.

---

## 5. Keys

Zap keyed on a bundle path with a bundle-identifier fallback. That works for a
switcher, which only ever draws applications. Jetty and Top Drawer draw files,
folders and links, so the key is a discriminated pair — `app`, `bundleID`, `file`,
`url` — serialised as `app:/Applications/Safari.app`.

An application is looked up by **path first, identifier second**. This is
load-bearing: site-specific-browser wrappers (Coherence, Unite, the Chrome/Electron
family) ship one bundle per site and every one reports the browser's identifier, so
an identifier-first ladder paints every wrapper with one icon. Writing the path key
retires the identifier key, or a stale entry resurfaces the day the app moves.

---

## 6. Resolution

```
3. the shared store ──── an icon the user chose, in any of the four apps
2. original artwork ──── read out of the bundle, unmasked
1. system icon ───────── whatever macOS hands us (returned as nil)
```

In Jetty and Top Drawer this sits *beneath* their existing per-item override, which
keeps winning. A per-item choice is more specific and was made more deliberately —
and two dock tiles pointing at one app are allowed to differ. Nobody's existing
icons change when they upgrade.

`IconResolver.icon(for:)` is a dictionary lookup and nothing else; a miss schedules
background work and returns `nil`. `IconRenderOptions` is the seam that keeps one
app's settings screen out of the library.

---

## 7. Migration

Zap has shipped `~/Library/Application Support/Zap/Icons/manifest.json` since its
first icon release, so there are real user choices to carry across.
`ZapManifestImport` runs once, maps each legacy key onto `app:` or `bundleID:` by
its leading slash, copies the PNGs, and then **renames** the old directory rather
than deleting it — a user who downgrades still has their icons.

Not a symlink from old to new: two writers and one inode is exactly the ambiguity
§3 removes.

---

## 8. Status and sequence

| Phase | | |
|---|---|---|
| **0** | `PictKit` exists; Zap builds against it, behaviour unchanged | package written, **not compiled** |
| **1** | Shared store, migration, watcher; Zap moves onto it | written, **not compiled** |
| **2** | Pict app: editor, ingestion, themes, search | not started |
| **3** | Jetty reads the store; un-jailing arrives in the dock | not started |
| **4** | Top Drawer the same | not started |
| **5** | Interchange packs — backup, transfer, sharing | not started |
| **6** | Opt-in system-wide application via `Icon\r`, and re-application after app updates | not started |

Phase 6 is the only one that writes outside Pict's own storage, and it is a separate
product decision. It is also the one that justifies Pict being an app at all rather
than a view: re-applying an icon after an app updates needs something watching
`/Applications`, and none of the three utilities should host that.
