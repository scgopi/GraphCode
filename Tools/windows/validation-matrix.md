# Windows port validation matrix

The Windows port must have runnable commands before implementation fleets begin.

## GraphCode

| Surface | Command |
|---|---|
| Windows investigation spikes | `pwsh Tools/windows/validate.ps1 -Task all` |
| Validation runner contract | `pwsh Tools/windows/Tests/ValidationRunner.Tests.ps1` |
| Deterministic visual baseline | `pwsh Tools/windows/validate.ps1 -Task visual-baseline` |
| TDD evidence contract | `pwsh Tools/tdd/Tests/TddEvidence.Tests.ps1` |
| Platform/wire contracts | `pwsh Tools/windows/validate.ps1 -Task swift-contracts` |
| Authenticated remote bridge proof | `pwsh Tools/windows/validate.ps1 -Task remote-bridge` |
| Windows-to-POSIX remote E2E parity | `pwsh Tools/windows/validate.ps1 -Task remote-e2e` |
| Hosted Windows without a WSL distribution | `pwsh Tools/windows/validate.ps1 -Task all -SkipWslRemoteE2E` |
| Production Swift platform package | `pwsh Tools/windows/validate.ps1 -Task swift-production` |
| Deterministic release hardening fixtures | `pwsh Tools/windows/validate.ps1 -Task hardening` |
| Signed catalog integrity and publisher policy | `pwsh Tools\windows\Tests\Packaging.Signing.Tests.ps1` |
| Native SignTool PS1 signature and tamper detection (SDK required) | `pwsh Tools\windows\Tests\Packaging.ScriptSigning.Tests.ps1` |
| Native missing/idle task stop and deletion | `pwsh Tools\windows\Tests\Packaging.Scheduler.Tests.ps1` |
| Failed-upgrade preservation and recoverable rollback | `pwsh Tools\windows\Tests\Packaging.Rollback.Tests.ps1` |
| Standalone setup under PowerShell 5.1 and 7 | `pwsh Tools\windows\Tests\Packaging.Standalone.Tests.ps1` |
| Release publishing: signing gates, asset labeling, workflow contract | `pwsh Tools\windows\Tests\Release.Tests.ps1` |
| Product/investigation provider pin consistency | `pwsh Tools\windows\Tests\ProviderPins.Tests.ps1` |
| Native release feed, URL handoff, and allocation safety | `pwsh Tools\windows\Tests\WindowsShell.Tests.ps1 -ZigExecutable $env:GRAPHCODE_ZIG0152` (includes updater tests) |
| Real-product packaging and source/standalone install/upgrade/rollback/uninstall | `pwsh Tools\windows\validate.ps1 -Task packaging` |
| Shared Swift package | `swift test --package-path <shared-package>` once extracted |
| macOS app/daemon/CLI | `make test` |
| macOS format/lint | `make check` |
| DCO commit range | `git log --format=%B <base>..HEAD` plus trailer validation |

## Required PR checks

The macOS shared-regression, Windows shell, Windows port, and Windows hardening
workflows run on every pull request, including documentation-only changes.
Workflow-level path/branch filters must not prevent their required check contexts
from being reported. `ValidationRunner.Tests.ps1` guards the unfiltered triggers.
This deliberately trades additional CI usage for reliable branch protection.

Check names and job behavior are unchanged. Full-pinned and owned-environment
hardening remain dispatch/schedule-gated as defined in the workflow; they are
separate evidence, not required PR contexts. No merge-queue support is introduced.

## Winghostty fork

`Tools/windows/bootstrap.ps1` checks out the public provider at the exact commit in
`graphcode-windows/provider-pins.json`. The GraphCode gates invoke its real build and
host contracts:

| Surface | Required command |
|---|---|
| Pinned provider build | `pwsh Tools/windows/validate.ps1 -Task windows-shell` |
| Host lifecycle and rendering contracts | `pwsh Tools/windows/validate.ps1 -Task terminal-gate` |
| Interactive Win32 smoke | `pwsh Tools/windows/validate.ps1 -Task windows-shell -SkipTrayLive` on hosted runners; omit `-SkipTrayLive` on an owned interactive desktop |
| Embeddable one/two-surface stress | `pwsh Tools/windows/validate.ps1 -Task terminal-gate` |

## zmx fork

The same bootstrap checks out zmx at its exact public pin. These gates exercise the real
provider rather than a placeholder implementation:

| Surface | Required command |
|---|---|
| Pinned provider build and smoke | `pwsh Tools/windows/validate.ps1 -Task terminal-gate` |
| GraphCode terminal behavior | `pwsh Tools/windows/validate.ps1 -Task windows-shell -SkipTrayLive` |
| Windows CLI compatibility | `pwsh Tools/windows/validate.ps1 -Task hardening` |
| Agent/session compatibility | `pwsh Tools/windows/validate.ps1 -Task all -SkipTrayLive -SkipWslRemoteE2E` on hosted runners |

## Shell request correlation

The shell gate and real-product hardening delay stub replies by 150 ms to exercise
project-subscription changes with requests still outstanding. The normal stub uses
the production listener's 64 KiB pipe buffers; the separate non-reading fixture
retains zero-sized buffers to exercise backpressure.

Subscription reconnects drain pending v1/v2 responses before closing the pipe,
bounded by the existing 1.5-second negotiation interval. Explicit reconnect and
close actions do not wait for that drain. The native tests also verify that
repeated subscription changes cannot extend the deadline.

Smoke actions wait for their connection/selection or workspace after the
earliest action tick instead of being lost when that one tick arrives too
early. Enqueuing an action resets the idle-exit counter. Large-paste resource
sampling waits for the owned `pwsh` attach and continues through the active
workload so the trend uses per-process peaks, not one startup instant.
Readiness, sampling, and completion share the same eight-second budget.

`STUB_DAEMON_EVIDENCE_JSON` records request/response counts, unanswered IDs and
commands, and the stub error before assertions run. Failed repeated hardening
prints its captured child output rather than discarding it. Session/resource
tracking uses exact test-owned CIM process matches and their descendants, not a
global `zmx list` that can hang on unrelated sessions.

Real high-output timeouts also emit `HARDENING_OUTPUT_DIAGNOSTICS_JSON`: captured
byte count, independent start/end marker offsets, attach/capture state, and at
most 512 bytes from each end of the synthetic transcript. This does not change
the payload, hash checks, or completion deadline.

Completion markers are located after ANSI and line-ending normalization, just
like the payload: ConPTY may insert color/title sequences or wrapping inside a
marker. Regression fixtures cover fragmented markers, multiple OSC titles,
incomplete/reversed markers, and empty completed output. The exact normalized
4 MiB length and SHA-256 checks still decide whether the payload passes.

## Remote SSH

Remote validation uses controlled POSIX hosts and sanitized fixtures:

- local bridge unit/security tests;
- mandatory-by-default deterministic local Windows-to-POSIX parity fixture covering setup,
  fan-out, messaging, reconnect, restart/reboot restoration, multiple hosts,
  generation monotonicity, and capability non-disclosure;
- Python shim protocol fixtures;
- SSH reconnect and stale-state tests;
- manual or protected CI tier for real remote-host execution. Set
  `GRAPHCODE_REMOTE_E2E_TARGETS` to comma-separated authenticated `user@host:port`
  values; configured targets are mandatory and failures fail the run. Empty entries
  are rejected.

Public GitHub-hosted Windows runners do not provide a configured WSL distribution.
Those workflows pass `-SkipWslRemoteE2E` explicitly, which skips only the WSL-backed
local fixtures; parser and protocol-independent remote E2E checks still run. Developer
and WSL-capable validation defaults remain fail-closed and run the complete fixture.

Credentials, hostnames, and capability tokens belong in runner secrets and never in the
repository.

## Final hardening executable matrix

The `hardening` task is mandatory and always runs deterministic local fixtures; it
does not turn into a pass when an environment is unavailable. The current measured
ceilings are:

| Dimension | Fixture and threshold |
|---|---|
| High output/backpressure | 4 MiB lossless output in <=10 seconds |
| Long duration | 3-second session completes in 2.5-10 seconds |
| Crash recovery | exit 17 is observed, then a fresh session succeeds |
| Multi-terminal | four concurrent 512 KiB sessions complete in <=15 seconds |
| Unicode/hostile paths | UTF-8 clipboard text round-trips through a >=180-character Unicode path |
| Process cleanup | fixture process count returns to baseline |
| Real product output/session | pinned zmx/ConPTY writes exactly 4 MiB plus a completion marker; session exit code is 0 within 90 seconds |
| Real resource ceilings | private memory <=512 MiB; per-run handle growth <=256; three-run private-memory range <=32 MiB and handle range <=64 |
| Repeatability | three consecutive runs; each reports process, handle, and private-memory deltas and all must pass |

GPU/WGL, real ConPTY/zmx reconnect, screen reader/UIA, physical DPI/display,
authenticated SSH, login/reboot, and installer ACL tests are environment-only.
They are explicitly gated by `Hardening.Tests.ps1 -Environment` and a runner-owned
PowerShell harness supplied through `GRAPHCODE_HARDENING_TARGET` (the repository
fixture is `Tools/windows/Tests/EnvironmentFixture.ps1`); selecting that
tier without the harness fails. The
deterministic tier remains mandatory on every pull request. The scheduled full
workflow runs the pinned provider/package lifecycle gate and cannot substitute a
skip for a missing provider.

The environment harness emits `schemaVersion=1` JSON with one result for every
mandatory dimension. A skipped dimension must include a non-empty reason.
Hardening includes RED checks proving missing dimensions and reasonless skips are
rejected; the deterministic Named Pipe fixture is reported separately.

The Windows host cannot execute macOS tests. `.github/workflows/macos-shared-regression.yml`
is the authoritative macOS matrix (`swift test`, `make test`, `make check`); only
the portable Swift package is executable locally on Windows.
