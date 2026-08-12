# zmx Windows feasibility

## Current architecture

zmx runs one daemon per session. The daemon owns the PTY, terminal/scrollback state,
labels, cwd, and child process. Clients attach through local IPC. State is memory-resident.

Its protocol currently includes tags 0-18, an asserted 8-byte packed header, and an
asserted 552-byte info structure. GraphCode uses at least:

```text
run <session> -d ...
attach <session>
send <session> <data>
get <session> [label]
set <session> <label=value>
kill <session>
```

## Unix implementation dependencies

- `forkpty`, termios, ioctl
- double fork, `setsid`, `/dev/null`, `dup2`
- `fork`, `execve/execvpe`, `waitpid`, `kill`, process groups
- AF_UNIX filesystem sockets and stale socket cleanup
- `poll`, self-pipe signal handling, SIGWINCH/SIGHUP/SIGTERM
- UID, XDG/HOME/TMP paths and POSIX modes
- `/bin/sh`, bash task mode, Unix quoting and utilities

## Windows mapping

| Unix | Windows |
|---|---|
| PTY/forkpty | ConPTY / `HPCON` |
| AF_UNIX | Named Pipes |
| process group | Job Object |
| fork/exec | `CreateProcessW` + `STARTUPINFOEX` |
| ioctl resize | `ResizePseudoConsole` |
| poll/signals | overlapped I/O plus event/IOCP waits |
| UID/XDG runtime path | per-user LocalAppData state |
| POSIX task shell | explicit PowerShell/cmd policy or deferred compatibility mode |

## Spike result

`investigation/spikes/zmx-conpty` combines ConPTY, Named Pipes, and a Job Object.

Validated in a custom line-protocol primitive spike:

1. Start an interactive child.
2. Send `echo BEFORE`.
3. Detach the client without killing the child.
4. Send `echo DETACHED` while detached.
5. Reattach and receive a snapshot containing both outputs.
6. Stop and remove the process tree; subsequent pipe connection fails.

This proves ConPTY child survival across short Named Pipe connections and Job Object
lifetime control. It does not prove zmx attach/detach parity:

- no real zmx header/tags or CLI implementation
- no long-lived bidirectional attach stream
- `DETACH` stores no attachment state
- `SNAPSHOT` returns a capped raw byte buffer, not libghostty-vt screen reconstruction
- no resize or concurrent attach leadership policy
- no real coding-agent TUI

## GraphCode fork risk

GraphCode pins `scgopi/zmx` commit `a8739f4f64f7b716f24cc51c4883938f4daaf284`.
Its mouse-input patch is still relevant but is 26 commits behind current upstream and
conflicts when cherry-picked. Rebase/upstream it before beginning Windows work.

## Decision

Run a source-integrated prototype against rebased zmx before approving the full port.
If it succeeds, port zmx as one cross-platform codebase with platform modules for
process/PTY, IPC, daemon lifecycle, event waits, resize/control, paths/security, and
shell tasks. Create a separate `zmx-win` only if upstream rejects the abstractions or
required CLI semantics.

Confidence:

- High: ConPTY, Named Pipe, and Job Object primitives.
- Medium-low: real zmx attach/VT/CLI, task mode, signal/control, agent TUI, and crash parity.
