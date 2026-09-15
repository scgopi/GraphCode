# Architecture decisions

## ADR-001: Keep orchestration and domain logic in Swift

### Status
Accepted for the port investigation.

### Evidence
Swift 6.3.3 built `IdentifiedCollections` and a 31-file GraphCode domain target on Windows.
JSON/settings tests passed. Source audit classifies 39 of 62 GraphcodeKit files as portable
unchanged and 17 as shared after abstraction.

### Decision
Keep GraphcodeKit and graphcoded orchestration in Swift. Add explicit platform services;
do not duplicate graph/session/backend policy in Zig or C++.

### Consequences
The Windows package must redistribute the Swift runtime. SwiftPM becomes a supported
shared-core build path alongside Tuist.

## ADR-002: Use a process boundary for the Windows shell

### Status
Accepted.

### Decision
The native Windows shell talks to Swift `graphcoded` through the daemon protocol. Do not
start with a Swift DLL/C ABI embedded in Zig.

### Evidence
The daemon already owns state and survives UI restarts. A Swift Named Pipe spike supports
the required local communication patterns.

### Consequences
UI crashes do not take orchestration down. Protocol correlation/versioning should be
hardened before multiple rich clients are shipped.

## ADR-003: Use Named Pipes for Windows daemon IPC

### Status
Accepted, pending security hardening.

### Evidence
The Swift/WinSDK spike passed request/response, events, simultaneous clients, reconnect,
unavailable-daemon, connection-availability timeout, and oversized-frame rejection.

### Decision
Retain JSON and four-byte length framing over a Windows Named Pipe transport.

### Consequences
Replace raw descriptors in `GraphStore` and `ProjectRegistry` with a connection abstraction.
Use overlapped I/O, connected-operation deadlines/cancellation, bounded frames, and an
explicit current-user ACL in production. Add request correlation/versioning before rich
multi-client use.

## ADR-004: Port zmx cross-platform rather than create zmx-win

### Status
Conditional; requires a source-integrated protocol prototype.

### Evidence
A Windows primitive spike combined ConPTY, Named Pipes, Job Objects, short client
connections, background output, a raw-buffer snapshot, and cleanup. It did not implement
zmx's actual protocol or long-lived attach behavior.

### Decision
First rebase GraphCode's mouse patch and build a prototype inside current zmx preserving
its wire ABI/CLI, long-lived attach, VT reconstruction, resize, and attach leadership.
Then add platform modules. Create a separate fork only if upstream rejects the required
boundaries or semantics.

### Consequences
The work is a real backend port, not a small compile fix, and approval remains conditional.
Task mode, signals, shell semantics, and event-loop plumbing need separate Windows
implementations.

## ADR-005: Do not declare Ghostty surface embedding solved by a VT-only spike

### Status
Accepted.

### Context
`libghostty-vt` can drive terminal state and public row/cell APIs in a GraphCode-owned
Win32 window. That is useful but is not the complete Ghostty renderer/application runtime.
Upstream's full embedder API is macOS/iOS-only and exposes no HWND surface API.

### Decision
Treat a full two-surface Ghostty renderer/input/IME/clipboard/accessibility spike as the
UI go/no-go gate. Do not commit the product to a Winghostty fork or to a custom GDI
terminal renderer based only on VT success.

### Consequences
Headless Windows work can proceed while the UI architecture remains provisional.

## ADR-006: Include POSIX remote SSH parity in Windows v1

### Status
Supersedes the earlier deferral decision.

### Evidence
Remote support embeds POSIX shell, Unix-domain sockets, chmod/shebang behavior, `/usr/bin/ssh`,
and reverse Unix socket forwarding throughout several files.

### Decision
Windows v1 includes the existing POSIX remote-host workflow. Keep Named Pipes as the local
daemon transport and bridge them through an authenticated, loopback-only TCP listener used
only by SSH reverse forwarding. The one-shot remote shim discovers the current endpoint and
capability through an atomic user-only bridge-state record.

Windows remote hosts, ARM64, and automatic updating remain deferred.
