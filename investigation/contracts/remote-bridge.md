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

## Gates

- invalid, expired, previous-generation, and missing capability tests
- daemon/SSH/remote restart rediscovery
- multiple hosts and projects
- network loss and stale state
- real remote create/send/memo/status through the tunnel
