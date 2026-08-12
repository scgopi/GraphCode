# zmx Windows platform contract

Provider: `coneilen/zmx`

## Preserve

- real zmx CLI and wire tags/header/info layout
- long-lived bidirectional attach
- terminal state and scrollback through libghostty-vt
- `run`, `attach`, `send`, `get`, `set`, `kill`, resize, labels, errors
- GraphCode non-leader mouse-input behavior

## Platform interfaces

- PTY/process lifecycle
- client/server local IPC
- event wait and cancellation
- resize/control events
- runtime paths and security
- daemon lifetime
- task-shell behavior

Windows implementations use ConPTY, Named Pipes, Job Objects, and explicit Windows process
creation. A custom line protocol or capped raw-output snapshot does not satisfy the contract.

## Multi-attach

Choose one explicit same-session policy: reject, shared attach, or leadership transfer.
Test input routing, resize ownership, transfer/rejection, detach/reconnect, and session
health with concurrent clients.

## Gates

- real CLI black-box tests
- VT reconstruction after detach/reconnect
- Unicode, bracketed paste, control events, stale cleanup, client/daemon crashes
- at least one real coding-agent TUI
