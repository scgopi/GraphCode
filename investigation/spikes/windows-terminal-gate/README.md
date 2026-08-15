# GraphCode Windows terminal gate

This spike is the smallest GraphCode-owned native shell that exercises the
terminal architecture before the product canvas, sidebar, or workspace exists.
GraphCode owns the top-level `HWND`, window procedure, and sole `GetMessageW`
loop. Winghostty owns two complete child surfaces. zmx owns the persistent
session/ConPTY lifetime.

## Provider pins

`provider-pins.json` records the accepted provider commits:

- Winghostty `a3786b20b2f96325b800814f4f0f8dba0c789d8a`
- zmx `858727af10cdf43d66cb3733cff58dc90ec4b3dd`

The Winghostty remote workflow cannot publish from the current workflow scope,
so the reproducible fallback is a local reviewed worktree. The build accepts
that worktree explicitly and keeps the future remote URLs in the metadata. No
provider source is copied into GraphCode.

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

The provider owns the rendering/input/IME/clipboard/per-monitor-DPI/UIA
semantics. The gate owns the caller-side renderer lifecycle, focus policy,
per-surface attach transport, and terminal-state notifications needed to verify
the embedding boundary.

`Tools\windows\validate.ps1 -Task terminal-gate` runs the contract plus the
pinned-provider build and smoke when the accepted local provider worktrees are
available. It reports an explicit skip only when those provider roots are
absent.

## TDD and validation evidence

The architecture contract was run RED before the gate files existed, then
GREEN after the Zig host, provider pins, and smoke harness were added.
`Tools\windows\Tests\TerminalGate.Tests.ps1` remains the fast architecture
contract check. The harness sends shell commands through zmx, verifies
`zmx history --vt` before and after independent and same-session restarts, and
runs the destroy/recreate stress cycle.

At the accepted provider SHAs, the Winghostty API lifecycle and input tests
pass. The renderer stress contract passes twice but intermittently fails on a
fresh run with error 259, observed as either reentrant callback retention or
numeric handle/process-heap growth; this is a provider-side blocker outside
the GraphCode-owned gate. GraphCode full Windows validation, formatting,
privacy, TDD evidence, and the terminal-gate smoke/stress harness pass.
