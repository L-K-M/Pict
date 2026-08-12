# CI/CD

Pict is two things in one repository — a SwiftPM package (`PictKit`) and a Swift/Xcode
macOS app (`App/`) — so its CI is the sibling apps' setup plus a second job. CI builds
and tests both on every change; the release workflow produces an unsigned,
ad-hoc-codesigned `Pict.app` packaged as a `.zip` and `.dmg`, then publishes a GitHub
Release.

## Workflows

| Workflow | Trigger | Purpose |
| --- | --- | --- |
| `.github/workflows/ci.yml` | Pull requests, pushes to `main`, manual dispatch | Build and test the package and the app with a pinned Xcode toolchain. |
| `.github/workflows/zai-code-review.yml` | Pull requests (opened / reopened / synchronize / ready for review) | Automated review pass with GLM 5.2. |
| `.github/workflows/release.yml` | Pushing a `v*` tag (e.g. `v1.2.0`) | Test both suites, build an unsigned `.app`, package `.zip` + `.dmg`, publish a GitHub Release. |

## Continuous integration (`ci.yml`)

Two jobs on `macos-14`, in parallel. In-progress runs for the same ref are cancelled
when a new commit is pushed.

Both select **Xcode 16.2** via `maxim-lobanov/setup-xcode` — pinned so a runner-image
bump can't silently change the toolchain.

| Job | What it runs |
| --- | --- |
| **Build & Test PictKit** | `swift build` then `swift test` |
| **Build & Test Pict.app** | `xcodebuild test` against the `Pict` scheme in `App/Pict.xcodeproj`, `CODE_SIGNING_ALLOWED=NO` |

**Why two jobs rather than one.** Building the app compiles `PictKit` — the app
references the package locally — but it does not run `PictKitTests`. That suite is the
half Zap, Jetty and Top Drawer actually depend on, so it needs running on its own.

`workflow_dispatch` is enabled. It was added when GitHub throttled webhook delivery
during an Actions incident and `pull_request` events stopped starting workflows at all;
dispatch goes through the API instead. It is worth keeping regardless — re-running CI
no longer needs an empty commit.

### Running CI checks locally

```sh
swift test

set -o pipefail
xcodebuild \
  -project App/Pict.xcodeproj \
  -scheme Pict \
  -destination 'platform=macOS' \
  -resultBundlePath TestResults.xcresult \
  CODE_SIGNING_ALLOWED=NO \
  clean test | xcbeautify
```

This requires Xcode 16.2 to match CI exactly. `xcbeautify` is optional (install with
`brew install xcbeautify`); drop the pipe to use raw `xcodebuild` output.

## PR review (`zai-code-review.yml`)

Runs GLM 5.2 over the diff and posts findings as a PR comment. Identical to Zap's and
Top Drawer's, and hardened the same way:

- It is a `pull_request_target` workflow, which exposes repository secrets and a
  write-capable token, so it **only runs for branches in this repository** — never for
  a fork's.
- The third-party action is pinned to an immutable commit rather than a moving tag.
- One review per PR at a time; a superseded review of an outdated diff is cancelled.
- Skips cleanly with a note when `ZAI_API_KEY` isn't configured, rather than failing.

Findings are advice, not a gate. `CLAUDE.md` in this repo describes how to triage them
— apply, decline with recorded reasons, or refute with evidence — and when to stop.

## Releases (`release.yml`)

To cut a release:

```
git tag v1.2.3
git push origin v1.2.3
```

Or use the helper, which also bumps the committed `MARKETING_VERSION` and the README
version line so local/dev builds report the same number, then creates and pushes the
tag:

```
scripts/release.sh 1.2.3 --push
```

The version is derived from the tag with the leading `v` stripped (e.g. `v1.2.3` →
`1.2.3`), and the build number is the workflow run number. The job runs on `macos-14`
with Xcode 16.2 — the same toolchain as CI, deliberately: a release built on a
toolchain CI has never used is a build nobody has tested.

It runs, in order:

1. **Both test suites.** A `v*` tag can land on any commit, including one CI never saw,
   and with no signing or notarization downstream the tests are the only automated
   quality check. `PictKitTests` runs too, because shipping a broken store would break
   the three apps that resolve this package, not just Pict.
2. An **unsigned** Release build of `Pict.app` (`CODE_SIGNING_ALLOWED=NO`), with
   `MARKETING_VERSION` set from the tag.
3. **Ad-hoc codesigning** (identity `-`), then `codesign --verify --deep --strict`.
4. A `Pict-<version>.zip` (via `ditto`) and a `Pict-<version>.dmg` (via `create-dmg`),
   with `hdiutil verify` on the image.

Both files are attached to a GitHub Release (named `Pict <version>`, with auto-generated
notes) via `softprops/action-gh-release`. A tag containing a hyphen (`v1.1.0-beta.1`) is
published as a prerelease and is not made "latest" — the three apps point users at
`releases/latest` from their "Get Pict" buttons, and a beta should not be what they land
on.

### Signing, and why it differs slightly from the siblings

Ad-hoc signing is not a Developer ID signature and the app is not notarized; it is only
required for the app to launch on Apple Silicon. Gatekeeper still warns, and the release
body tells users to right-click → Open or run
`xattr -dr com.apple.quarantine /Applications/Pict.app`.

Zap and Jetty sign with `codesign --deep`. Pict signs **inside-out** instead — nested
code in `Contents/Frameworks` first, then the bundle — because `--deep` is deprecated
for signing, and because Pict is the only one of the four with a SwiftPM dependency in
its own build. A library product normally links statically and leaves nothing nested, in
which case the loop does nothing; if `PictKit` is ever built as a dynamic framework, it
has to be signed before the bundle enclosing it. The `--verify --deep --strict` step
after it exists because the failure mode is a download that simply refuses to launch,
which nothing upstream would catch.

## Secrets

| Secret | Used by | Required? |
| --- | --- | --- |
| `ZAI_API_KEY` | `zai-code-review.yml` | Optional — the job skips with a note when unset. |

Neither `ci.yml` nor `release.yml` uses repository secrets beyond the automatically
provided `GITHUB_TOKEN` (which `action-gh-release` uses to create the release). Releases
are intentionally unsigned, so no Apple certificates or notarization credentials are
required.
