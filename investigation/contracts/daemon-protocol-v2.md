# Daemon protocol v2 contract

## Compatibility

- Existing protocol-v1 frames remain valid.
- The daemon identifies v2 only when a frame contains the explicit envelope `version` or
  `kind` fields.
- A v2 client sends `hello` and negotiates the highest shared version.
- Protocol-v1 clients continue receiving their existing event shapes.
- Protocol-v1 retirement is outside the Windows port.

## Envelope

Protocol v2 uses the existing four-byte big-endian frame header and a bounded JSON payload.

Kinds:

- `hello`: supported versions
- `request`: request ID and `DaemonCommand`
- `response`: request ID and `DaemonEvent`
- `event`: sequence and `DaemonEvent`
- `error`: optional request ID plus stable code/message

The maximum payload is initially 1 MiB. Transport implementations must handle partial
reads/writes, deadlines, cancellation, backpressure, and non-reading peers.

## Subscription and reconnect

- Responses are correlated only by request ID.
- Events carry a monotonically increasing connection-visible sequence.
- Subscription selection and replay-window policy must be added before the Windows shell
  consumes v2.
- A reconnect never silently treats an unrelated event as command acknowledgement.

## Test fixtures

- Frozen current Swift CLI command.
- Frozen current macOS app command/event exchange.
- Frozen delivered Python remote-shim command.
- Interleaved v2 requests and events.
- Unsupported version, malformed envelope, partial/oversized frame, timeout, and reconnect.
