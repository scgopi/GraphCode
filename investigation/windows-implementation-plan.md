# GraphCode Windows implementation plan

Durable tracking:

- GraphCode meta issue: https://github.com/scgopi/GraphCode/issues/89
- Winghostty provider: https://github.com/coneilen/winghostty/issues/1
- zmx provider: https://github.com/coneilen/zmx/issues/1

This document is the repository copy of the approved multi-session plan. GitHub issues,
provider commits, and the integration commit stack are the cross-session source of truth.
Session-local SQL todos mirror the IDs below and can be reconstructed from this document.

## Approach

- Keep GraphcodeKit, orchestration, persistence, backend policy, and resume behavior in Swift.
- Build Windows `graphcoded.exe` and `graphcode.exe` around secure Named Pipes.
- Port real zmx protocol/CLI semantics to ConPTY and Named Pipes.
- Extract a complete embeddable `win32_host` Zig package from a maintained Winghostty fork.
- Build a native Zig/Win32 GraphCode shell that owns product UI and workspace layout.
- Support existing POSIX remote hosts in the first Windows release through an authenticated
  SSH-only loopback TCP bridge to the local Named Pipe daemon.
- Preserve GraphCode's visual identity with native Windows controls and accessibility.

## Red/green/refactor rule

Every feature, extraction, protocol change, security behavior, UI flow, packaging change,
and bug fix follows:

1. **RED:** add the focused automated test/contract first and observe the intended failure.
2. **GREEN:** implement the smallest correct behavior and pass the same command.
3. **REFACTOR:** improve structure while the focused and adjacent regression tests stay green.

PRs record:

```text
RED: <command> -> <expected failure>
GREEN: <command> -> pass
REGRESSION: <command(s)> -> pass
```

Deliberately failing commits are not integrated. Green test and implementation land
together in a bisectable, DCO-signed commit.

## Worktree and integration model

- The Windows integration branch is the only GraphCode aggregation branch.
- Every task uses a dedicated worktree and branch.
- A task records todo ID, repository, owner, base SHA, owned files, RED/GREEN evidence,
  regression command, provider pin, PR, integration commit, blockers, and next dependency
  in GraphCode issue #89.
- After green validation and review, commit with `git commit -s`, rebase the committed
  branch onto the required integration SHA, rerun tests, and integrate with
  `git cherry-pick -x`.
- No two fleet agents own overlapping files or contracts.
- Provider changes land and are pinned before GraphCode consumer commits.

## Provider repositories

### Winghostty

Repository: `coneilen/winghostty`

Extract `win32_host` so:

- GraphCode supplies the parent HWND and owns the sole message loop;
- the host owns terminal child windows, renderer, input, IME, clipboard, DPI, and UIA;
- configuration is copied at creation;
- teardown guarantees no later callbacks or renderer/process access;
- original Winghostty behavior remains green.

### zmx

Repository: `coneilen/zmx`

- Rebase GraphCode's non-leader mouse behavior onto current upstream.
- Add platform interfaces before Windows implementations.
- Preserve the real zmx header, tags, CLI, labels, long-lived attach stream, terminal-state
  reconstruction, resize, detach/reconnect, error semantics, and tested multi-attach policy.
- A custom proof protocol or raw-output snapshot is not acceptance.

## Cross-platform contracts

Freeze serially before implementation fleets:

- `PlatformPaths`
- `ProcessRunner`
- `ShellStrategy`
- `ByteStream`
- `DaemonConnection` / `DaemonListener`
- dual-stack daemon protocol
- `SessionService`
- `StartupManager`
- `RemoteBridge`
- Winghostty host ownership contract
- zmx platform interfaces

The daemon accepts deployed protocol-v1 app/CLI/shim clients unchanged. Protocol v2 begins
only after negotiation and adds request IDs, typed responses/errors, event sequencing,
subscriptions, reconnect, and replay policy.

## Remote SSH contract

The first Windows release supports existing POSIX remote hosts:

- local GraphCode continues using Named Pipes;
- one per-host bridge listens on ephemeral `127.0.0.1`;
- SSH reverse forwarding binds a remote-loopback TCP port;
- a versioned `0600` bridge-state record contains instance/generation, port, capability,
  rotation data, and protocol version;
- the one-shot Python shim reads that record for every command;
- strict host-key checking, forward-failure detection, effective loopback-bind verification,
  token rotation, stale cleanup, and explicit diagnostics are required;
- macOS retains Unix-socket forwarding.

## Visual contract

Preserve:

- neutral near-black canvas/window tones and subtle graph-paper grid;
- dark glossy terminal chrome;
- rounded loop cards with type accent stripe and entry port;
- redundant state color/shape/text;
- monospaced live/meta text;
- orange needs-you warmth, glow, border, and review rail;
- focused split ring and unfocused pane veil;
- terminal-first information density.

Use deterministic graphs, IDs, event streams, state, metrics, clock, and static terminal
snapshots for image fixtures. Test live Winghostty surfaces functionally. Native titlebar,
menus, dialogs, focus cues, and keyboard conventions may adapt to Windows.

## Durable todo registry

| ID | Deliverable |
|---|---|
| `win-bootstrap` | DCO, validation matrix, forks, issues, worktree conventions |
| `win-tdd-harness` | TDD evidence, fixtures, CI, committed plan |
| `win-contracts` | Frozen platform/protocol/provider/remote contracts |
| `win-wing-baseline` | Reproducible Winghostty baseline |
| `win-zmx-rebase` | Current zmx plus GraphCode mouse behavior |
| `win-visual-baseline` | Deterministic visual fixtures |
| `win-swift-platform` | Shared Swift package, paths, process, shell |
| `win-protocol-dualstack` | v1 compatibility and v2 correlation/subscriptions |
| `win-wing-host-api` | Embeddable Winghostty host API |
| `win-zmx-platform` | zmx OS interfaces |
| `win-remote-spike` | Restart-safe authenticated bridge proof |
| `win-daemon-pipe` | Windows daemon and CLI |
| `win-wing-renderer` | Terminal renderer extraction |
| `win-wing-input` | Input/IME/clipboard extraction |
| `win-wing-access` | DPI/UIA extraction |
| `win-wing-examples` | External host/lifecycle tests |
| `win-zmx-conpty` | ConPTY/process backend |
| `win-zmx-ipc` | Named Pipe backend |
| `win-zmx-attach` | Real attach/VT/multi-attach |
| `win-zmx-agent` | Coding-agent compatibility |
| `win-remote-bridge` | Production SSH bridge/shim |
| `win-terminal-gate` | Two persistent rendered terminals |
| `win-shell-scaffold` | Native shell foundation |
| `win-sidebar` | Sidebar/global overview |
| `win-canvas` | Project graph canvas |
| `win-workspace` | Terminal tabs/splits/focus |
| `win-forms` | Forms/settings/navigation |
| `win-attention-worktree` | Attention/worktree flows |
| `win-ui-integrate` | Integrated visual/accessibility UI |
| `win-remote-e2e` | POSIX remote parity |
| `win-packaging` | Signed installer/runtimes |
| `win-hardening` | Performance/security/hardware/regressions |
| `win-final-pr` | Final reviewed GraphCode PR |

## Execution sequence

### Serial bootstrap

1. Correct DCO history.
2. Land runnable validation matrix.
3. Land TDD harness and this committed plan.
4. Land serial contracts and record `CONTRACT_BASE`.

### Provider baseline fleet

- Winghostty baseline/CI/dependency graph.
- zmx upstream rebase and GraphCode mouse patch.
- deterministic GraphCode visual fixtures.

### Foundation fleet

- shared Swift platform services;
- dual-stack daemon protocol;
- Winghostty host API skeleton;
- zmx platform interfaces/real Windows protocol build;
- remote bridge state/security spike.

Integrate serially and publish `FOUNDATION_BASE`.

### Platform fleet

- Windows daemon/CLI;
- Winghostty renderer, input/IME/clipboard, DPI/UIA;
- zmx ConPTY and Named Pipes;
- production remote bridge.

Provider gates precede GraphCode pins. Publish `TERMINAL_BASE` only after the external
two-surface and real zmx attach tests pass.

### Shell and UI fleets

- terminal architecture gate;
- Windows shell scaffold;
- sidebar/overview;
- graph canvas/cards/edges;
- terminal workspace;
- forms/settings/navigation;
- attention/worktree flows;
- visual/accessibility integration.

### Remote, packaging, and hardening

- POSIX remote-host end-to-end parity;
- Windows CI, installer, signing, runtime/license packaging;
- session/crash/performance, GPU, DPI, IME, screen reader, security, path, remote, and
  macOS regression matrices.

## Bug filing

For a pre-existing GraphCode bug:

1. reproduce on unchanged public `main`;
2. add a regression test and observe RED;
3. search existing issues;
4. file immediately with sanitized evidence and the RED command/failure;
5. link it from the task/PR ledger;
6. use a dedicated fix worktree if it blocks the port.

Port-introduced bugs stay in the owning worktree. Provider bugs are filed only when
reproducible against their public repositories.

## Release gate

- local and POSIX-remote sessions remain persistent, attachable, and steerable;
- two or more complete rendered terminal surfaces coexist reliably;
- graph/sidebar/workspace behavior and visual identity meet the parity contract;
- keyboard, DPI, IME, clipboard, UIA, installer, and security gates pass;
- macOS behavior remains green;
- provider provenance and exact pins are documented;
- the integration branch contains a reviewed, signed, bisectable commit stack ready for
  one PR to `main`.
