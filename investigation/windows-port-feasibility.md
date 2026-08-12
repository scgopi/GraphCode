# GraphCode Windows port feasibility

## Executive decision

**A native Windows port is feasible, but the architecture in the handoff is only partly
proven.**

- **Go**: shared Swift domain/orchestration, Windows `graphcoded`, CLI, Named Pipe IPC,
  and Windows paths/process services.
- **Conditional go**: a cross-platform zmx backend. The OS primitives are feasible, but
  the spike does not preserve zmx's real wire protocol, long-lived attach behavior, or
  terminal snapshot semantics.
- **Conditional go**: the Windows UI. `libghostty-vt` works and can back multiple custom
  Win32 terminal views, but that does not yet prove a complete Ghostty-rendered surface
  with input, IME, clipboard, accessibility, DPI, and multi-surface composition.
- **Defer**: remote SSH parity, ARM64, and production installer/updater.

The recommended program is therefore headless-first. Do not begin the graph editor until
the complete two-terminal Ghostty host gate passes.

## Evidence produced

| Spike | Result | Decision impact |
|---|---|---|
| Full GraphcodeKit SwiftPM build | Dependencies build; GraphCode compilation stops at unconditional `import Darwin` in `PTYProcessSession` | Swift dependency graph is viable; platform seams are source-level, not a Swift-on-Windows blocker |
| Portable Swift domain | 31 files compile; graph/settings JSON tests pass | Core domain remains Swift |
| Windows path behavior | Reproduced drive-path rejection, malformed support override, unsafe persistence filename | Paths require an early platform abstraction |
| Swift Named Pipes | Request/response, events, multiple clients, reconnect, unavailable daemon, connection-availability timeout, and oversized-frame rejection pass | `graphcoded` can remain Swift and use WinSDK directly; connected-I/O deadlines remain open |
| Swift `Process` | Direct exe preserves argv/Unicode/cwd/env; `.cmd` works; `.ps1` needs PowerShell host | Foundation `Process` is viable with explicit extension/shell policy |
| zmx ConPTY primitives | ConPTY + Named Pipe + Job Object; short connections, background output, raw-buffer snapshot, stop all pass | OS primitives are feasible; actual zmx protocol/attach parity remains unproven |
| Ghostty VT custom window | `libghostty-vt` builds; two independent child terminal views render in one GraphCode-owned HWND | VT/state embedding is feasible; full Ghostty surface remains a separate gate |

Spike source and commands are under `investigation/spikes/`.

## Material corrections to the handoff

1. **Daemon transport is not isolated to two socket files.** `GraphStore` and
   `ProjectRegistry` own raw `Int32` descriptors and write frames directly.
2. **`PTYProcessSession` is not merely an old interactive path.** It runs zmx control
   commands, label reads, sends, kills, log probes, and remote commands. Split it into a
   pipe-based process runner and zmx's interactive ConPTY backend.
3. **Current path handling is functionally incompatible with Windows.** This affects
   project admission, support-directory overrides, and persistence filenames.
4. **Remote support is not a small SSH executable-path change.** It depends on POSIX
   shells, AF_UNIX, chmod/shebangs, control sockets, and reverse Unix socket forwarding.
5. **`libghostty-vt` Windows support is not proof of a full reusable Ghostty surface.**
   The handoff conflates terminal state APIs with the renderer/application runtime.
6. **The GraphCode zmx fork is stale.** Its mouse-input patch remains relevant but is 26
   upstream commits behind and conflicts when moved to current upstream.
7. **Swift toolchain setup needs to be explicit.** The official 6.3.3 toolkit, runtime
   DLL path, Windows SDK root, MSVC libraries, and Git bare-repository policy all affected
   the spike. CI must codify this rather than assume `swift` on PATH is sufficient.

## Recommended architecture

```text
GraphCode shared Swift package
  domain, graph, persistence, backend/session policy
                    |
             graphcoded (Swift)
                    |
       protocol + length framing
         /                    \
 Unix socket/macOS       Named Pipe/Windows
         |                    |
 SwiftUI/AppKit shell   native Windows shell
         |                    |
 GhosttyKit            full Ghostty host gate
         |                    |
       zmx          cross-platform zmx + ConPTY
```

Required shared interfaces:

- `DaemonConnection` / `DaemonListener`
- `ByteStream`
- `PlatformPaths`
- `ProcessRunner`
- `ShellStrategy`
- `SessionService`
- `StartupManager`

Do not put platform conditionals throughout `ZmxSessionLauncher`. Keep backend/resume/
message policy shared and move command construction/execution behind those services.

## zmx feasibility

zmx is portable in architecture but not in implementation. Current Unix dependencies
include `forkpty`, double-fork daemonization, AF_UNIX, `poll`, signals/self-pipe, termios,
ioctl resize, process groups, UID/XDG paths, `/bin/sh`, and Unix quoting.

The Windows spike demonstrated the enabling OS behavior:

```text
start ConPTY child
send BEFORE
detach client
send DETACHED while detached
reattach and receive snapshot containing both
stop and clean the process tree
```

It did **not** implement zmx's real 8-byte-header/tagged protocol, a long-lived
bidirectional attached client, libghostty-vt reconstruction, resize, or concurrent attach
leadership. Its `attach` is a one-shot raw-buffer snapshot and `detach` records no client
state.

Recommendation:

1. Rebase the GraphCode mouse patch onto current upstream zmx.
2. Introduce platform modules for PTY/process, IPC, daemon lifecycle, event wait, paths,
   resize/control, and task shell.
3. Preserve the existing 8-byte IPC header, 552-byte info structure, tags, CLI names, and
   GraphCode-used commands (`run -d`, `attach`, `send`, `get`, `set`, `kill`).
4. Before committing to the backend port, build a source-integrated zmx prototype that
   preserves the real wire ABI/CLI and proves long-lived attach, detach, reconnect with
   VT reconstruction, resize, concurrent attach policy, and one real agent TUI.
5. Add black-box compatibility tests before changing GraphCode.

Confidence is high for the Windows primitives and medium-low for full zmx protocol/task/
signal/agent parity.

## Ghostty/Winghostty feasibility

Positive evidence:

- `libghostty-vt` builds on Windows.
- Its public C API exposes terminal lifecycle, VT writes, resize, render snapshots,
  row/cell iterators, styles/colors/graphemes, key/mouse/focus encoders, selection, and
  paste validation.
- Public terminal row/cell state can drive two independent child views in one
  GraphCode-owned top-level HWND.
- Multiple terminal states are not inherently a blocker.

Negative evidence:

- Upstream `ghostty.h` is explicitly an internal macOS/iOS embedder API and has no HWND
  platform payload.
- Upstream Ghostty has no Win32 application runtime or public Windows
  `create_surface(parent_hwnd)` equivalent.
- `libghostty-vt` provides no windowing, ConPTY, process launch, GPU context, font shaping,
  glyph atlas, compositor, clipboard ownership, or event routing.

Not yet proven:

- reuse of Ghostty's production renderer rather than a custom GDI renderer
- complete keyboard layout and IME behavior
- mouse selection and clipboard
- accessibility/UIA
- DPI and teardown under repeated surface recreation
- compositor behavior with graph canvas plus two live terminal surfaces
- a maintainable build against current Winghostty/Ghostty revisions

Winghostty proves the topology is possible: its internal `Host` owns the top-level HWND
and child `Surface` values own HWND/HDC/HGLRC/CoreSurface instances and WGL rendering.
However, this boundary is internal and tightly coupled across `win32.zig`, `Surface.zig`,
`App.zig`, renderer/OpenGL, compositor, clipboard, UIA, tabs/splits, shell, IPC, recovery,
and settings modules. Winghostty is valuable source evidence, not a safe dependency
decision yet. Its tested build has a Zig-version/path conversion failure, while newer Zig
is API-incompatible.

**UI gate:** a GraphCode-owned window containing two complete Ghostty-rendered surfaces,
each running a command and independently handling focus/input/resize/clipboard/IME. Until
that passes, “Zig + Win32 using Ghostty/Winghostty” remains a preferred hypothesis. The
two feasible implementation choices are both substantial:

1. extract/maintain Winghostty's internal Win32/OpenGL runtime; or
2. use `libghostty-vt` and build GraphCode's own production renderer/input stack.

## Delivery plan and measured estimate

| Phase | Exit condition | Estimate |
|---|---|---:|
| 1. Shared Swift extraction | Cross-platform package, paths/process abstractions, shared tests | 3-5 engineer-weeks |
| 2. Windows daemon + CLI | Secure Named Pipe, multi-client events, local graph commands, startup | 3-5 weeks |
| 3. zmx Windows backend | CLI compatibility, ConPTY detach/reattach, resize, Unicode, crash tests | 6-10 weeks |
| 4. Full terminal-host gate | Extracted Winghostty runtime or production custom renderer; two surfaces with input/IME/clipboard/DPI | 8-16 weeks, very high uncertainty |
| 5. Minimal native shell | Project list, graph, node actions, one workspace, state updates | 8-12 weeks |
| 6. parity/hardening | Tabs/splits, attention UX, accessibility, packaging, agents | 8-14 weeks |

Total: roughly **36-62 engineer-weeks** before remote parity and ARM64. One experienced
engineer should expect approximately 9-16 months; a small parallel team can reduce
calendar time, but the terminal-host gate is not parallelizable away.

## Go/no-go checkpoints

Proceed now with phases 1-2 and a source-integrated zmx prototype. Treat the complete zmx
backend as conditional on that prototype.

Do not approve the full product port budget until:

1. the full two-surface Ghostty host gate passes;
2. zmx runs at least one real coding agent through detach/send/reattach;
3. Named Pipe ACLs, connected read/write deadlines, cancellation, and frame bounds are proven;
4. request correlation, version negotiation, event-subscription semantics, and interleaved
   multi-client tests are complete;
5. Swift runtime packaging size and installer behavior are measured.

If the Ghostty host gate fails, reconsider the UI host/renderer choice without discarding
the successful shared Swift, daemon, CLI, and zmx work.
