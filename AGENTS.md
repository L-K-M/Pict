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

<!-- shared-rules:start -->

## Working practices

- Follow explicit task instructions over the default workflow below.
- Before editing, inspect the branch and working tree, fetch remote updates,
  and fast-forward where safe. Never overwrite existing work to update.
- Resolve ambiguity before making consequential changes. State low-risk
  assumptions; ask when scope, safety, or expected behavior is unclear.
- Keep changes focused. Do not modify unrelated code, formatting, or comments.
- Prefer surgical edits over whole-file rewrites when the result is equivalent.
- Stage only intended files. Inspect the diff before committing.

## Communication

- Be concise, factual, and direct. Preserve necessary context and uncertainty.
- Avoid praise, motivational filler, emojis, and em dashes in new prose.
- Address the reader directly in user-facing copy.
- Report what was verified and what remains unverified. Never imply that an
  unavailable check passed.

## Code design

- Prefer early returns and shallow nesting. Separate logical blocks with
  blank lines.
- Use descriptive constants or enums for meaningful or repeated values.
  Use existing standard definitions for protocol/specification constants.
  Keep obvious, one-off values inline.
- Use enums for behavioral modes that would otherwise require ambiguous
  boolean arguments.
- Default members to private. Widen visibility only for required consumers,
  and review the change as an API design decision.
- Follow the repository's declared dependency boundaries. UI and controllers
  must use application services rather than directly accessing databases,
  subprocesses, sockets, or other low-level mechanisms.
- Encapsulate low-level mechanics behind domain-oriented interfaces.
- Reuse genuinely shared logic. Avoid speculative abstractions and layers
  that only forward calls.
- Prefer pure functions for business rules and immutable data where practical.
  Isolate side effects; document non-obvious state ownership or synchronization.
- Explain non-obvious intent, constraints, and tradeoffs in comments.
  Do not narrate obvious code. Add examples or diagrams when they clarify it.

## Validation and errors

- Validate untrusted input at entry points. Where practical, represent valid
  states in types and enforce persistent invariants in database schemas.
- Represent absence and failure explicitly.
- Use assertions for internal programming invariants, not external-input
  validation or required runtime error handling.
- Prefer explicit, actionable errors over silent failure or undocumented
  fallback. Document intentional recovery behavior.
- Never report a skipped or failed operation as successful.

## Bug fixes

1. Identify the root cause and define an observable success criterion.
2. Add a regression test and observe the relevant failure before fixing it.
3. Implement the fix and observe the test passing.
4. Check surrounding behavior for regressions and architectural consistency.

If an automated regression test is impractical, document the reproduction
and verification procedure. State any inability to reproduce the failure.

## Verification

- Run relevant tests and lint after changes.
- Choose coverage by affected behavior and risk, not patch size.
- Use integration or end-to-end tests for critical workflows and boundaries;
  test isolated business rules at the lowest effective level.
- Run broader suites for cross-cutting or high-risk changes, and the full
  required release checks before releasing.
- Validate the requested command, options, platform, and configuration.
  Unrelated green CI is not proof that the reported problem is fixed.
- Recheck after the final edit. Distinguish local checks from CI results.

## Commit messages

- Use a capitalized, imperative subject without a final period.
- Target 50 characters; never exceed 72.
- Separate the subject and body with one blank line.
- Wrap body text at 72 characters.
- Explain what changed and why. Leave implementation mechanics to the code.

## Implementation and review

Unless explicitly instructed otherwise:

1. Work on a focused branch and open a PR against main.
2. Inspect CI results and completed review feedback for the latest commit.
   A successful reviewer job does not mean the review found no problems.
3. Address important findings or explain why they do not apply. Handle minor
   findings according to the stopping rules below.
4. Evaluate each fix in the surrounding project, add regression coverage,
   and rerun affected checks before pushing.
5. Repeat until a stopping criterion is met.
6. Merge without asking again once the stopping criterion is met, required
   checks pass on the latest commit, and no unresolved blockers or required
   human review requests remain.

### Automated review stopping rules

Judge findings by verified impact, not the reviewer's severity label.
Important findings concern correctness, security, data loss, broken builds,
or materially degraded behavior/performance.

Track completed review rounds and consecutive rounds without important
findings. Reruns of the same revision and integration failures do not count.

- No applicable actionable feedback: finish immediately.
- First minor-only round: optionally fix worthwhile, low-risk findings.
  Do not manufacture another push merely to obtain another review.
- Two consecutive rounds without important findings: stop responding to
  automated nitpicks, even if actionable minor suggestions remain.
  Defer worthwhile leftovers rather than continuing the cycle.
- A confirmed important finding resets the minor-only streak. Address it
  and verify the fix before continuing.

After ten completed rounds, enter stabilization:

- Stop optional cleanup, refactoring, and nitpick fixes.
- One completed review without confirmed important findings is sufficient
  to finish, even if minor suggestions remain.
- Continue only for confirmed important defects. If resolving them stalls,
  report the blockers rather than continuing indefinitely.

These limits end optional automated-feedback work. They do not waive
confirmed blockers, unresolved human review requests, or required checks.

### Reviewer integration failures

After two consecutive reviewer-integration failures, stop and report the
review gap. Do not treat failures as approval. An explicit user instruction
may waive review; report that waiver rather than claiming review passed.

## Completion checklist

- The requested behavior is implemented without unrelated changes.
- Relevant checks pass for the latest code.
- Important review findings are addressed or rejected with reasons.
- Deferred suggestions, remaining risks, and validation gaps are disclosed.
- The final response accurately states whether work is committed, pushed,
  and merged.

<!-- shared-rules:end -->
