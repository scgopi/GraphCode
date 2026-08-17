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

The graph surface also provides native Win32 create/edit forms for nodes and
edges, a settings dialog, context menus, and keyboard-accessible actions:
`Ctrl+N` creates a node, `Ctrl+E` edits the selected node, `Ctrl+J` advances
selection, and `Ctrl+,` opens settings. Mutations are sent as correlated v2
daemon requests; daemon refusals remain visible as explicit status errors.

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

## Tray lifecycle coverage

The shell registers a version-4 notification icon with a stable `HWND`/icon ID
identity, restores through the same callback path used by Explorer, and
re-registers after `TaskbarCreated`. `TrayLive.Tests.ps1` retains physical
`Shell_NotifyIconGetRect` discovery (including monitor and DPI checks), while
its test-only registered-message hook relays Open and context events back
through and observes the production notification callback. This avoids treating
injected screen coordinates as a reliable substitute for overflow-tray
activation. The context test locates the live popup and its actual `Exit` item,
verifies the menu label and command ID, and activates it with physical input
rather than injecting a command message.

When another shell owns the named startup reservation, daemon supervision opens
it for synchronization and waits only for the bounded reservation interval.
After release it checks the endpoint and daemon lifetime lock again, so a
failed competitor is replaced by an owned daemon while a successful one is
never duplicated.
