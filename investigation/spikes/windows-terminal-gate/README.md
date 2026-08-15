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

The `--smoke` mode focuses both surfaces independently, injects DPI/IME/
clipboard/accessibility events, destroys and recreates surface A while B stays
alive, and exits after synchronous teardown. `--stress` repeats the A
destroy/recreate cycle. Running the smoke process twice proves that the zmx
sessions survive GraphCode exit and are reattached on restart. The gate never
calls GraphCode canvas/sidebar code and does not duplicate daemon orchestration;
the existing Windows daemon remains an independent service.

The provider owns the full rendering/input/IME/clipboard/per-monitor-DPI/UIA
implementation. The gate only supplies caller-owned lifecycle, focus policy,
and terminal-state notifications needed to verify the embedding boundary.

## TDD and validation evidence

The architecture contract was run RED before the gate files existed, then
GREEN after the Zig host, provider pins, and smoke harness were added.
`Tools\windows\Tests\TerminalGate.Tests.ps1` remains the fast contract check.
The harness seeds VT output with `zmx print`, verifies `zmx history --vt`
before and after independent and same-session restarts, and runs the
destroy/recreate stress cycle.

At the accepted provider SHAs, the Winghostty API lifecycle and input tests
pass. The renderer stress contract passes twice but intermittently fails on a
third fresh process with `reentrant callback surfaces remained retained
(error=259)`; this is a provider-side blocker outside the GraphCode-owned gate.
GraphCode full Windows validation, formatting, privacy, TDD evidence, and the
terminal-gate smoke/stress harness pass.
