# GraphCode Windows shell

This is the production Zig/Win32 shell scaffold. It owns the top-level `HWND`,
the single Win32 message loop, sidebar/project chrome, graph surface, workspace
layout, and focus policy. GraphcodeKit and `graphcoded` remain the only owners of
graph/session orchestration and business rules.

The shell connects to the current-user GraphcodeKit Named Pipe using the v2
length-prefixed JSON envelope and falls back to the v1 command/event frame only
when the daemon does not negotiate v2. Commands and events are encoded from the
fixtures in `fixtures/`, which mirror the GraphcodeKit Codable wire shapes.

Each terminal surface is a real Winghostty surface under the GraphCode parent
window and attaches to the persistent zmx session for its selected node. Surface
destruction kills only the attach client; zmx owns the session and survives shell
restarts. The host contract is the accepted two-surface terminal-gate contract,
not a synthetic terminal proof.

## Build

Use the exact provider pins in `provider-pins.json` and clean local worktrees:

```powershell
zig build `
  -Dwinghostty-dir=<pinned-winghostty-worktree> `
  -Dwinghostty-lib=<pinned-winghostty-worktree>\zig-out\lib\winghostty-win32-host.lib `
  -Doptimize=ReleaseSafe
```

`Tools\windows\validate.ps1 -Task windows-shell` performs pin, clean-worktree,
format, lifecycle-contract, and real provider build checks. This scaffold has
package metadata only; it intentionally does not create an installer.
