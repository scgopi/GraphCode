# Authenticated Windows remote-bridge spike

This is an isolated contract proof. It does not change `GraphcodeKit` or the existing
remote implementation. The Python fixture models the local Windows bridge and a
Named Pipe-like four-byte framed backend using loopback sockets so the same test runs
on Windows and POSIX.

## Run

```text
python -B -m unittest discover -s investigation/spikes/remote-bridge -p test_*.py -v
pwsh Tools/windows/validate.ps1 -Task remote-bridge
```

`remote_client.py` is a one-shot, POSIX-compatible shim. It reads the state record for
each request and sends one framed JSON request:

```text
python investigation/spikes/remote-bridge/remote_client.py STATE.json "{\"command\":\"status\"}"
```

The test fixture starts the backend and bridge itself; no real host, credential, SSH
endpoint, or private network is used.

## Proofed behavior

- `schema_version` and `protocol_version` are validated on every state read.
- Capabilities contain 256 random bits and are never included in diagnostics.
- TTL and all current/previous-generation timestamps must be finite; expiry cannot be
  disabled with `NaN` or infinity.
- State writes use a user-only temporary file, flush and `fsync`, then `os.replace`.
- The listener is explicitly bound to `127.0.0.1`; Windows uses exclusive-address binding
  when available.
- A requested-port collision retries with an ephemeral loopback port.
- Rotation issues a new generation and permits at most one bounded previous generation.
- Expired, missing, malformed, oversized, and invalid-token requests are rejected.
- Stop/restart replaces stale state and a one-shot client rediscovers the new record.
- Backend failures return a stable sanitized error.
- Tests keep bridge state in OS temporary storage outside the repository.
- `RemoteBridgePrivacyRace.Tests.ps1` runs remote tests and privacy validation concurrently.

## TDD evidence

RED: `python -B -m unittest discover -s investigation/spikes/remote-bridge -p test_*.py -v` -> initial import failure, then non-finite TTL/state tests failed
GREEN: `python -B -m unittest discover -s investigation/spikes/remote-bridge -p test_*.py -v` plus `pwsh Tools/windows/Tests/RemoteBridgePrivacyRace.Tests.ps1` -> 16 tests and race regression passed
REGRESSION: `pwsh Tools/windows/validate.ps1 -Task remote-bridge` -> focused Windows validation, privacy race, and finite-expiry checks passed

## Required production contract changes

This spike does not claim production readiness. Before integration, the production
contract must additionally specify:

1. A Windows user-only ACL for the state record and Named Pipe, with an explicit test
   that another local user cannot read or connect.
2. Overlapped Named Pipe I/O with cancellation and bounded deadlines, preserving the
   existing four-byte frame limit and protocol-v2 envelope.
3. SSH reverse forwarding with strict host-key verification, `ExitOnForwardFailure`,
   explicit remote `127.0.0.1` binding, and verification of the effective listener.
4. A production stale-state ownership check and cleanup policy that cannot remove a
   newer daemon's record.
5. Protected integration tests for reconnect, remote restart, multiple projects, and
   real `create`/`send`/`memo`/`status` exchanges using runner-provided fixtures only.
