# Windows remote bridge contract

The first Windows release supports existing POSIX remote hosts.

## Topology

```text
remote one-shot Python shim
  -> authenticated remote-loopback TCP endpoint
  -> SSH reverse forwarding
  -> authenticated local 127.0.0.1 bridge
  -> Windows graphcoded Named Pipe
```

macOS retains its current Unix-socket forwarding path.

## Bridge state

An atomically replaced user-only record contains:

- schema version
- local daemon instance ID
- forward generation
- remote loopback port
- capability
- issued/expiry data
- protocol version

The record uses `schema_version: 1` and `protocol_version: 1`. `host` is always the
literal `127.0.0.1`; a client must reject another host. `capability` is at least
32 random bytes encoded as lowercase hexadecimal. `generation` is monotonically
increasing for a daemon instance. A rotation may include one `previous` generation
with an explicit finite expiry, bounded by the configured overlap maximum. `issued_at`
and `expires_at` must be finite numeric values, and a configured TTL must be finite and
positive. Readers must re-read the record for every one-shot command.

The one-shot shim reads the record on every command, so already-running zmx sessions
discover replacements after daemon restart, SSH reconnect, remote reboot, or shim upgrade.
Rotation permits a bounded prior generation to avoid update races.

## Security

- random capability of at least 256 bits
- strict host-key verification
- `ExitOnForwardFailure`
- explicit remote bind to `127.0.0.1`
- verification of the effective listener despite server `GatewayPorts`
- collision retry, expiry, stale cleanup, and sanitized diagnostics
- no network-exposed or unauthenticated daemon transport

The isolated `investigation/spikes/remote-bridge` proof demonstrates these state,
framing, authentication, rotation, expiry, collision, restart, and loopback
properties with a POSIX-compatible Python shim and a Named Pipe-like framed backend.
It is not a production implementation.

## Gates

- invalid, expired, previous-generation, and missing capability tests
- daemon/SSH/remote restart rediscovery
- multiple hosts and projects
- network loss and stale state
- real remote create/send/memo/status through the tunnel

## Required production changes

Before integration, production must add a current-user Windows ACL for both the state
record and Named Pipe, overlapped Named Pipe I/O with cancellation/deadlines, and
strict SSH reverse-forward checks (`StrictHostKeyChecking`, `ExitOnForwardFailure`,
explicit remote `127.0.0.1`, and effective-listener verification). Production must
also define ownership-safe stale cleanup and protected-host integration fixtures.
