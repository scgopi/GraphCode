# Open questions and go/no-go gates

## Must answer before production UI work

1. Can a GraphCode-owned Win32 window host the complete Ghostty renderer/input stack, not only `libghostty-vt` state rendered by a custom GDI client?
2. Can two complete surfaces share a compositor without focus, DPI, IME, accessibility, or teardown leaks?
3. Which Winghostty modules can be extracted on a maintained Zig/Ghostty revision?
4. What upstream relationship will prevent GraphCode from carrying a permanent Ghostty application-runtime fork?

## Must answer before daemon release

1. Exact current-user Named Pipe ACL and SID-derived naming.
2. Overlapped-I/O deadlines/cancellation for connect, header read, body read, and writes.
3. Maximum frame size, backpressure, partial-frame, and non-reading-peer behavior.
4. Protocol request correlation/versioning; the current “next matching broadcast” behavior is fragile with multiple active clients.
5. Event subscription, ordering, and reconnect/replay semantics for multiple clients.
6. Windows startup choice: Startup shortcut, scheduled task, packaged app startup task, or explicit app-managed child.
7. Swift runtime redistribution and installer footprint.
8. Authenticated bridge-state schema, capability rotation, stale cleanup, and endpoint
   rediscovery after daemon/SSH/remote restart.
9. Verification that the SSH server's effective reverse-forward listener remains
   loopback-only regardless of `GatewayPorts`.

## Must answer before zmx release

1. Rebase/upstream the GraphCode mouse-input patch.
2. Define multiple attach leadership behavior on Windows.
3. Verify VT snapshot restoration against real ConPTY streams and coding-agent TUIs.
4. Test resize, Ctrl+C/Ctrl+Break, Unicode, bracketed paste, stale-session cleanup, daemon/client crashes, and reboot recovery.
5. Decide whether task-mode POSIX shell features are supported natively, through PowerShell, or deferred.

## Deferred from Windows v1

- WSL-specific project/path integration.
- ARM64.
- Full updater/installer automation.
