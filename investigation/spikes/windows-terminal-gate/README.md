# GraphCode Windows terminal gate

This spike is the smallest GraphCode-owned native shell that exercises the
terminal architecture before the product canvas, sidebar, or workspace exists.
GraphCode owns the top-level `HWND`, window procedure, and sole `GetMessageW`
loop. Winghostty owns two complete child surfaces. zmx owns the persistent
session/ConPTY lifetime.

## Provider pins

`provider-pins.json` records the accepted provider commits:

- Winghostty `e0a5579f3b470bede72294d661282a391c502ace`
- zmx `785b3fd15dcafd1882b495c831a10f98c201b908`

Both commits are publicly reachable in the `coneilen` provider repositories.
The bootstrap creates detached, exact-revision checkouts without copying
provider source into GraphCode.

The annotated `graphcode-windows-baseline-2026-09-17` tags preserve the original
baseline sources, including zmx `029e11d2b19162fb3bdf90c8270237d303b8bfb4`,
not the current zmx pin. The provider forks protect these tags against
updates/deletion and the dedicated branches against deletion/history rewrites; see
`Tools\windows\PACKAGING.md` for the recorded ruleset IDs and retention limits.
These are source-retention tags, not signed Windows releases.

The current zmx pin includes the merged Windows named-pipe accept-deadline race
fix from [coneilen/zmx#4](https://github.com/coneilen/zmx/pull/4), following the
SetSize control-plane commit from [coneilen/zmx#3](https://github.com/coneilen/zmx/pull/3).
That earlier commit provides the `zmx attach <session> --size <cols>x<rows>`
and leaderless one-shot `zmx resize <session> <cols>x<rows>` CLI verbs. This
spike does not yet exercise either verb; GraphCode's pane-geometry integration
in `graphcode-windows\src\TerminalSurface.zig` is what calls them.

`graphcode-windows\fixtures\zmx-quick-chat-provider.json` is historical
quick-chat provenance at the old provider SHA and recorded source/executable
paths. It is not an active pin assertion or evidence of a build at the new SHA.

`graphcode-windows\provider-pins.json` is authoritative. The terminal gate's
contract compares its schema and all provider fields against this copy, and
`Tools\windows\Tests\ProviderPins.Tests.ps1` injects drift into both sides.
Changing only one copy must fail validation; JSON property order and explanatory
fallback wording do not change the provider identity.

## Build

Build Winghostty's host artifact at its pinned local SHA, build zmx at its
pinned Windows integration SHA, then run:

```powershell
zig build `
  -Dwinghostty-dir=<path-to-winghostty-worktree> `
  -Dwinghostty-lib=<path-to-winghostty-worktree>\zig-out\lib\winghostty-win32-host.lib `
  -Doptimize=ReleaseSafe
```

Set `GRAPHCODE_ZMX` to the pinned `zmx.exe` for the gate process. The default
surface commands are `zmx attach graphcode-terminal-gate-a` and
`zmx attach graphcode-terminal-gate-b`; `--same-session` deliberately shares
the A session and exercises zmx's shared-attach policy.

## Gate behavior

The `--smoke` mode focuses both surfaces independently, exercises DPI/IME/
clipboard/accessibility events, types an `echo` command through Winghostty's
text/key callbacks, and verifies the resulting output arrives through the
per-surface `zmx attach` pipes. Attach stdout is accumulated into the
Winghostty terminal/accessibility text path and requests a real
`surface_render`/`surface_present` pair; any provider error fails the gate.

Surface A is destroyed and recreated while B remains alive. Recreate stops and
reaps only the attach client, leaving the zmx session daemon persistent.
`--stress` repeats this cycle. Running the smoke process again verifies typed
output and VT history survive GraphCode exit and are visible after reattach.
The gate never calls GraphCode canvas/sidebar code and does not duplicate daemon
orchestration; the existing Windows daemon remains an independent service.
Each attach child is spawned with `GRAPHCODE_GATE_CWD`; the first-session
smoke sends the shell's `cd`/pwd query and verifies the repository root.
Cleanup checks every `zmx kill` exit, confirms the named registrations and
reported processes disappear, and fails the gate if cleanup is incomplete.
`GRAPHCODE_TERMINAL_GATE_INJECT_CLEANUP_FAILURE=1` is a failure-injection
contract used to prove cleanup errors cannot produce a green result.

The provider owns the rendering/input/IME/clipboard/per-monitor-DPI/UIA
semantics. The gate owns the caller-side renderer lifecycle, focus policy,
per-surface attach transport, and a parsed VT cell snapshot that it submits
through `winghostty_surface_set_terminal_cells`; UI Automation text remains a
separate accessibility snapshot. The provider renderer draws those cells, so
typed echo and restored history are pixel/cell-observable rather than
accessibility-only.

`Tools\windows\validate.ps1 -Task terminal-gate` runs the contract plus the
pinned-provider build and smoke. Missing or dirty provider roots fail the task;
there is no green validation result without the real provider smoke.

## TDD and validation evidence

The architecture contract was run RED before the gate files existed, then
GREEN after the Zig host, provider pins, and smoke harness were added.
`Tools\windows\Tests\TerminalGate.Tests.ps1` remains the fast architecture
contract check. The harness sends shell commands through zmx, verifies
`zmx history --vt` before and after independent and same-session restarts, and
runs the destroy/recreate stress cycle.

At the accepted provider SHA, the Winghostty API lifecycle, input, pixel cell
render, and three-process renderer stress contracts pass. GraphCode full
Windows validation, formatting, privacy, TDD evidence, and the terminal-gate
smoke/stress harness are run only with clean pinned provider worktrees.
