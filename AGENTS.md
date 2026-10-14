# AGENTS.md

Guidance for coding agents working in this repository. Read
[CONTRIBUTING.md](CONTRIBUTING.md) first; everything there — licensing, the
[DCO](DCO) sign-off, and the pull request expectations — applies here too.

## Overview

GraphCode ships on macOS and is being ported to Windows.

- **macOS is the primary, shipping platform.** The app (`graphcode/`), daemon
  (`graphcoded/`), and CLI (`graphcode-cli/`) are built with Xcode through
  Tuist, driven by the root `Makefile`.
- **Windows is the in-progress port chasing parity.** It lives in
  `graphcode-windows/` and is written in Zig, with its own pinned toolchain and
  its own bootstrap script.
- **`GraphcodeKit/` is shared Swift** used by both.

Telling platforms apart by path:

| Path | Platform |
| --- | --- |
| `graphcode/`, `graphcoded/`, `graphcode-cli/`, `Project.swift`, `Tuist/`, `Makefile` | macOS |
| `graphcode-windows/`, `Tools/windows/`, `windows-tests/` | Windows |
| `GraphcodeKit/`, `Package.swift`, `Package.resolved` | Shared Swift |
| `investigation/` | Research notes and the parity ledger |

Work on the platform your task names. Do not "fix" the other platform in
passing.

## Shared rules

These apply to every change, on either platform.

### Sign-off and pull requests

- Sign off every commit (`git commit -s`); the DCO check is required. Keep
  commit messages UTF-8 with LF endings.
- Fill in [the pull request template](.github/PULL_REQUEST_TEMPLATE.md),
  including its checklist, and state the test plan's limits honestly.
- Keep one change per pull request, and describe the problem it solves rather
  than the files it touches.
- Keep changes scoped to the files your task owns. Several agents work in
  parallel across this repo, and overlapping edits to shared surfaces such as
  `App.zig`, `GraphModel.zig`, `NativeForms.zig`, and `GraphStore.swift` need
  explicit coordination.
- Never force-push a branch another session owns, and never bypass required
  checks.

### The RED/GREEN/REGRESSION gate

`.github/workflows/tdd-evidence.yml` runs `Tools/tdd/Test-TddEvidence.ps1`
against the pull request body on every open, edit, synchronize, and reopen. The
body must contain literal `RED:`, `GREEN:`, and `REGRESSION:` lines. Each one
must be at least 8 characters, must use `command -> result` form, and must not
contain an angle-bracket placeholder or the words TODO, TBD, or N/A. There is
no exemption, so write the lines from commands you actually ran.

The angle-bracket rule applies to the **entire line**, not just to the template's
scaffolding, and abbreviating a long path as an angle-bracketed token is the most
common way this check fails. Write the real path, or shorten it without brackets.
Validate the body before you publish:

```powershell
pwsh -NoProfile -File Tools\tdd\Test-TddEvidence.ps1 -BodyPath .\pr-body.md
```

Because the checker matches the first `RED:`/`GREEN:`/`REGRESSION:` line anywhere
in the body, including inside an HTML comment, never start a line with one of those
labels in example or guidance text. `Tools/tdd/Tests/TddEvidence.Tests.ps1` asserts
that the shipped pull request template is still rejected, which is what keeps an
unedited template from passing as real evidence.

This mirrors the working practice: write the test, observe it fail for the
intended reason, then implement, then re-run something wider. Preserve the
failing output rather than replacing it with the passing run.

### Evidence honesty

Overstated evidence has repeatedly caused rework. Be exact about what you ran.

- Distinguish a **compile** failure (a missing API) from a **behavioral**
  failure. A compile error is not proof of runtime behavior.
- Never overwrite a failing log with a passing one, and never fold a corrected
  mistake silently into a success summary.
- A green build, a filtered test run, or a green CI workflow does **not**
  establish native keyboard input, accessibility conformance, real glyph
  rendering, daemon persistence, cross-platform parity, or hardware behavior
  unless that exact path ran.
- A manually dispatched workflow run is not the same as a pull request's
  required checks.
- An **empty result is not a passing result.** A query that returns no rows
  cannot distinguish "nothing failed" from "nothing ran" — assert a non-zero
  count before drawing any conclusion from it. This applies to CI status
  queries and log greps as much as to `--test-filter`.

### The parity ledger

[investigation/ui-parity-matrix.md](investigation/ui-parity-matrix.md) is the
Windows UI parity ledger. It is a source-derived completion ledger, not a
requirements sketch: a row is `Validated` only when the Windows implementation
exposes the same user-visible information and actions as macOS *and* has runtime
evidence. When your evidence is a build or a unit test rather than a live
walkthrough, the row stays `Partial`.

### Sandbox hygiene

Use your own scratch, cache, config, and build directories, and redirect
`TEMP`/`TMP` where applicable. Never write into another worktree's or session's
build directory; treat other sessions' artifacts as strictly read-only.

---

## macOS

### Prerequisites

`make doctor` is the macOS entry point. Unlike the Windows bootstrap it
**installs nothing** — it checks every build prerequisite and prints the exact
fix for anything missing:

```sh
make doctor
```

It reports on `mise`, `tuist`, installed Tuist dependencies, `swiftlint`,
`xcbeautify`, the Swift toolchain, Xcode, `Project.swift`, the
`ThirdParty/ghostty` and `ThirdParty/zmx` submodules, a zig-linkable macOS 15
SDK, the Metal toolchain, and the built `zmx` and `GhosttyKit.xcframework`.

Typical first-run sequence, following what `doctor` asks for:

```sh
brew install mise
mise install                      # pinned tools from mise.toml
git submodule update --init --recursive
mise exec -- tuist install        # Tuist/SwiftPM dependencies
```

Pinned tool versions live in `mise.toml`: `tuist` 4.197.3, `swiftlint` 0.65.0,
`xcbeautify` 3.2.1, and `zig` 0.15.2. Apple's `swift-format` ships with the
Xcode toolchain and is deliberately not pinned there. The `Makefile` runs the
pinned tools through `mise exec --`; do the same rather than calling a tool
straight off `PATH`.

### Building, testing, and linting

The Xcode project is generated, not committed: `make generate` runs
`tuist generate --no-open` against `Project.swift`, producing
`graphcode.xcworkspace`. The schemes are `graphcode` (app), `graphcoded`
(daemon), and `graphcode-cli`, all built for `platform=macOS`.

```sh
make build-app        # or build-daemon / build-cli
make run-app          # builds, installs zmx, then opens graphcode.app
make test             # xcodebuild test for the graphcode scheme
make check            # swiftlint lint + swift format lint --strict
make format           # swift format --in-place + swiftlint --fix
```

`make check` and `make format` use `.swiftlint.yml` for SwiftLint and
`.swift-format` for the formatter, across `GraphcodeKit`, `graphcode`,
`graphcode-cli`, and `graphcoded`.

Other targets worth knowing: `install-zmx`, `build-ghostty`, `vendor-sdk`,
`install-cli`, `daemon-install` / `daemon-uninstall` / `daemon-status`,
`release-dmg`, `notarize`, `signing-doctor`, and the `dev-*` family for a
side-by-side local-development install.

### The macOS toolchain trap: the Zig SDK shim

Zig 0.15.2 cannot link against macOS SDK 26.x. That SDK dropped the plain
`arm64-macos` target from the primary `libSystem` document in
`usr/lib/libSystem.B.tbd`, leaving only `arm64e-macos`. Zig targets `arm64`,
finds no matching target, and concludes libSystem exports nothing — so every
libc symbol comes back undefined. Apple's own linker falls back from `arm64` to
`arm64e`; Zig 0.15.2's self-hosted MachO linker does not. The failure is not
specific to this repository: even `zig build --help` fails the same way.

Zig has no `SDKROOT` support and resolves the SDK by shelling out to exactly
`xcrun --sdk macosx --show-sdk-path`. `Tools/zig-sdk-shim/xcrun` intercepts that
one query, answers it with a macOS 15 SDK, and delegates everything else to the
real `xcrun`. The `Makefile` prepends the shim to `PATH` for every Zig build, so
`make build-zmx` and `make build-ghostty` already do the right thing. If you
invoke Zig directly on macOS, do the same:

```sh
PATH="$PWD/Tools/zig-sdk-shim:$PATH" zig build ...
```

The shim resolves its SDK from `GRAPHCODE_ZIG_SDK` if set, then a vendored
`.build/sdk/MacOSX15*.sdk` (see `make vendor-sdk`), then the newest
`MacOSX15*.sdk` in the Command Line Tools. Read the script's header before
changing any of this — installing a second, older Xcode is *not* required.

`make build-ghostty` additionally needs the Metal toolchain
(`xcodebuild -downloadComponent MetalToolchain`), and both Zig builds pass
`-Doptimize` deliberately: a Debug `zmx` relays about 0.3 MB/s and is not usable
for interactive work.

### Local overrides

The `Makefile` does `-include .env` then `-include .env.local`, so `.env.local`
wins when both exist, and command-line assignments (`make run-app FOO=bar`) beat
both. Both files are gitignored; `.env.example` is tracked and documents the
`DEV_*` variables used by the `dev-*` targets. Keep credentials out of them.

### macOS CI

`.github/workflows/macos-shared-regression.yml` runs on `macos-26` for every
pull request that touches macOS-relevant paths. It checks out submodules
recursively, runs `python3 Tools/portable-prepare.py`, installs mise and the
pinned tools, runs `swift test --package-path investigation/spikes/swift-portable`,
then `tuist install`, `make install-zmx`, `make test`, and `make check`.

### Path-gated CI

On pull requests, the Windows, macOS shared Swift, and Linux build jobs run only
when `Tools/ci/classify-changes.sh` finds relevant changed paths, so a
documentation-only change (for example `investigation/ui-parity-matrix.md`)
skips them; skipped jobs still satisfy their required checks. DCO, TDD
evidence, and the investigation privacy scan always run. Pushes, merge queue, schedules, manual dispatches, unknown
paths, and classifier failures all get full validation. When you add a directory
a suite builds or reads, add it to the classifier and its tests
(`bash Tools/ci/tests/classify-changes.test.sh`).

---

## Windows

### Bootstrap before anything else

Start with the
[Windows contributor quick start](graphcode-windows/README.md#windows-contributor-quick-start)
for the pinned build/run/stop path, measured reference timings, sandbox
behavior, and evidence limits.

**Do not hand-roll a toolchain environment, and do not install toolchains by
hand.** The repository already pins and resolves everything:

```powershell
pwsh -NoProfile -File Tools\windows\bootstrap.ps1
```

It installs the pinned Swift, downloads both pinned Zig versions, clones each
pinned provider and checks it out at its pinned commit, and writes
`.graphcode-tools\environment.ps1`. Bootstrap does not build the providers —
they are built later by the build and test tasks, which pass the provider roots
in (for example `-Dwinghostty-dir`).
Load that script in each new shell:

```powershell
. .\.graphcode-tools\environment.ps1
```

It exports the variables the build and test scripts expect:

| Variable | Purpose |
| --- | --- |
| `GRAPHCODE_SWIFT633` | Full path to the pinned `swift.exe` |
| `GRAPHCODE_ZIG0152` | Zig 0.15.2, for the Windows shell |
| `GRAPHCODE_ZIG0160` | Zig 0.16.0, required only by `zmx` |
| `GRAPHCODE_WINGHOSTTY_ROOT` | Pinned Winghostty provider root |
| `GRAPHCODE_ZMX_ROOT` | Pinned zmx provider root |

Pass `-SkipSwift` when you only need Zig and the providers; `-ToolRoot` and
`-ProviderRoot` relocate the tool and provider directories if the defaults
(`.graphcode-tools` and `.graphcode-tools\providers`) do not suit your session.
Zig downloads allow three retries by default, stop an attempt after 30 seconds
without response data, and share a 15-minute overall budget per archive. Tune
those bounded values with `-ZigRetryCount`, `-ZigStallTimeoutSeconds`, and
`-ZigOverallTimeoutSeconds`. Set `GRAPHCODE_ZIG_MIRROR` or pass `-ZigBaseUrl`
to replace the `https://ziglang.org` base URL; the pinned SHA-256 remains
mandatory for every source.

The bootstrap retains a checksum-verified `zig-<version>.zip` for reuse. A
corrupt cached or completed archive is deleted and never extracted. Interrupted
transfers remain as `zig-<version>.zip.partial` and resume with HTTP Range on
the next attempt or run; an exhausted retry budget reports that path instead of
discarding useful bytes. Hosted CI prints attempt boundaries and throttles byte,
speed, and ETA updates to avoid noisy logs.

Bootstrap enables `core.longpaths=true` only in each provider repository and
can resume a provider checkout that its own prior run left incomplete. If it
warns that the checkout exceeds the legacy path budget, use a short repository
root such as `C:\src\GraphCode`; pass `-ToolRoot C:\gc-tools` and
`-ProviderRoot C:\gc-providers` to shorten the downloaded dependencies. Some
repository test fixtures also require the checkout itself to be short.

### Pinned versions

These are the single source of truth. Never silently upgrade one.

| Tool | Version | Pinned in |
| --- | --- | --- |
| Swift | 6.3.3 | `.github/workflows/windows-*.yml` (`swift-version: swift-6.3.3-release`), `Tools/windows/bootstrap.ps1` |
| Zig (shell) | 0.15.2 | `mise.toml`, `graphcode-windows/build.zig.zon` (`minimum_zig_version`) |
| Zig (zmx only) | 0.16.0 | `graphcode-windows/provider-pins.json` |
| Winghostty | `6286560d0aa3103e068b2b7afa81eac373d870c9` | `graphcode-windows/provider-pins.json` |
| zmx | `785b3fd15dcafd1882b495c831a10f98c201b908` | `graphcode-windows/provider-pins.json` |

If a build fails because a tool is missing or the wrong version, rerun
bootstrap. Do not fall back to whatever is on `PATH`.

### The Swift toolchain trap

`swift` on `PATH` is usually **not** the pinned toolchain, and a mismatched
toolchain fails against the `swift-tools-version: 6.0` manifest. Always use
`$env:GRAPHCODE_SWIFT633`, or the pinned toolchain's `bin` directory, rather
than a bare `swift`.

Two failure modes cost real time, so recognize them:

- **`swift --version` exits with `0xC0000139`
  (`STATUS_ENTRYPOINT_NOT_FOUND`).** The toolchain `usr\bin` is on `PATH` but
  the matching `Runtimes\<version>\usr\bin` is not. Add both, and prefer
  invoking `swift-build.exe` / `swift-test.exe` directly over the `swift`
  driver.
- **A development / "unknown-Asserts" toolchain under
  `C:\Library\Developer\Toolchains` wins on `PATH`.** It is not the pinned
  toolchain. Ignore it.

A working SwiftPM environment needs `SDKROOT` pointing at the pinned
`Platforms\<version>\Windows.platform\Developer\SDKs\Windows.sdk`, plus MSVC
`INCLUDE`/`LIB` for the installed Visual Studio and Windows SDK. Set these
**process-only**; never mutate machine or user environment variables.

### Building and testing

```powershell
# Windows shell (Zig) — run from graphcode-windows
& $env:GRAPHCODE_ZIG0152 test src\<File>.zig --test-filter "<filter>"
& $env:GRAPHCODE_ZIG0152 build -Doptimize=ReleaseSafe -Dwinghostty-dir=$env:GRAPHCODE_WINGHOSTTY_ROOT

# Repository validation
pwsh -NoProfile -File Tools\windows\validate.ps1 -Task windows-shell -SkipTrayLive
pwsh -NoProfile -File Tools\windows\validate.ps1 -Task packaging
```

Zig test roots that import native headers need explicit target and link flags,
for example:

```
-target x86_64-windows-msvc -lc -luser32 -lgdi32 -ladvapi32 -I<winghostty>\include
```

A `--test-filter` that matches **zero** tests still exits successfully. Always
assert a positive executed test count; a filter typo is not a pass.

New Zig test roots must be registered in `Tools/windows/Tests/WindowsShell.Tests.ps1`,
which derives coverage from literal `& $zig test src\<File>.zig` invocations.

---

## Cross-platform parity

`GraphcodeKit/` is the shared Swift layer, and `Package.resolved` pins
`swift-collections` 1.6.0 and `swift-identified-collections` 1.1.1 for both
platforms. A change there affects the shipping macOS app as well as the port, so
treat it as the highest-risk surface in the repository and validate on both
sides before claiming it is safe.

When building the shared package with the pinned Windows toolchain, use
`--disable-automatic-resolution`. That flag alone can still fetch missing
checkouts, so also set `protocol.allow=never` process-only when you intend a
strictly offline build. If a checkout is genuinely missing, reuse an existing
local one at the exact revision in `Package.resolved` and verify with
`git rev-parse` before building. Never resolve a different version, and never
edit `Package.resolved` to make a build pass.

What parity means, per the ledger: the Windows implementation exposes the same
user-visible information and actions as macOS, with runtime evidence.
Platform-native chrome may differ. Since 2026-10-13, the macOS app is the ground truth, so a requirement macOS lacks
is not parity, and visual fidelity (layout, hierarchy, components, typography,
colour, wording) is part of parity, checked against paired macOS captures. See
[the orchestration plan](investigation/windows-parity-orchestration-plan.md). What parity does **not** mean: hiding a
feature behind an undocumented shortcut, replacing a structured screen with raw
protocol fields, or a passing Zig unit test standing in for a live walkthrough.
When in doubt, record the row as `Partial` and say why.
