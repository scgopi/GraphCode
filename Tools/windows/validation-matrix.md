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
- Python shim protocol fixtures;
- SSH reconnect and stale-state tests;
- manual or protected CI tier for real remote-host execution.

Credentials, hostnames, and capability tokens belong in runner secrets and never in the
repository.
