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
| Production Swift platform package | `pwsh Tools/windows/validate.ps1 -Task swift-production` |
| Deterministic release hardening fixtures | `pwsh Tools/windows/validate.ps1 -Task hardening` |
| Shared Swift package | `swift test --package-path <shared-package>` once extracted |
| macOS app/daemon/CLI | `make test` |
| macOS format/lint | `make check` |
| DCO commit range | `git log --format=%B <base>..HEAD` plus trailer validation |

## Winghostty fork

The fork bootstrap must replace these placeholders with exact pinned commands before
extraction work begins:

| Surface | Required command |
|---|---|
| Original application build | pinned Zig build command |
| Full test suite | pinned Zig test command |
| Interactive Win32 smoke | worktree-isolated smoke harness |
| Embeddable host | external one/two-surface tests after the package exists |

## zmx fork

The fork bootstrap must replace these placeholders with exact pinned commands before the
Windows backend fleet begins:

| Surface | Required command |
|---|---|
| Existing upstream tests | pinned Zig test command |
| GraphCode mouse behavior | focused parser/input tests |
| Windows CLI compatibility | black-box `run/attach/send/get/set/kill` suite |
| Agent compatibility | controlled real-agent smoke tier |

## Remote SSH

Remote validation uses controlled POSIX hosts and sanitized fixtures:

- local bridge unit/security tests;
- mandatory deterministic local Windows-to-POSIX parity fixture covering setup,
  fan-out, messaging, reconnect, restart/reboot restoration, multiple hosts,
  generation monotonicity, and capability non-disclosure;
- Python shim protocol fixtures;
- SSH reconnect and stale-state tests;
- manual or protected CI tier for real remote-host execution. Set
  `GRAPHCODE_REMOTE_E2E_TARGETS` to comma-separated authenticated `user@host:port`
  values; configured targets are mandatory and failures fail the run. Empty entries
  are rejected.

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
| Repeatability | three consecutive runs; each reports process delta and all must pass |

GPU/WGL, real ConPTY/zmx reconnect, screen reader/UIA, physical DPI/display,
authenticated SSH, login/reboot, and installer ACL tests are environment-only.
They are explicitly gated by `Hardening.Tests.ps1 -Environment` and a runner-owned
PowerShell harness supplied through `GRAPHCODE_HARDENING_TARGET` (the repository
fixture is `Tools/windows/Tests/EnvironmentFixture.ps1`); selecting that
tier without the harness fails. The
deterministic tier remains mandatory on every pull request. The scheduled full
workflow runs the pinned provider/package lifecycle gate and cannot substitute a
skip for a missing provider.

The Windows host cannot execute macOS tests. `.github/workflows/macos-shared-regression.yml`
is the authoritative macOS matrix (`swift test`, `make test`, `make check`); only
the portable Swift package is executable locally on Windows.
