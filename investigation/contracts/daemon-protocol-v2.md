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
- `response`: request ID and either a `DaemonEvent` or explicit `success: true` with no
  payload
- `event`: sequence and `DaemonEvent`
- `error`: optional request ID plus stable code/message

The v2 envelope payload is limited to 1 MiB after the envelope is identified. Legacy v1
frames retain their UInt32 length header and are accepted through the documented 2 MiB
legacy safety ceiling, which bounds allocation while preserving the deployed oversized
fixtures. Transport implementations must handle partial reads/writes, deadlines,
cancellation, backpressure, and non-reading peers.

## Subscription and reconnect

- Responses are correlated only by request ID.
- Events carry a monotonically increasing connection-visible sequence.
- `hello` may carry a `clientID`, `resumeFrom` cursor, and an optional project-path
  subscription allow-list. An omitted allow-list subscribes to every joined project.
- The daemon keeps a bounded replay window per logical `clientID` (128 events by default),
  with bounded client count and expiry, independent of a socket. A reconnect replays events
  strictly after `resumeFrom`; unknown or expired history receives `replayUnavailable`, while
  a cursor beyond the retained latest sequence receives `cursorOutsideWindow`.
- Canonical subscribed graph events are retained for a logical client while its socket is
  disconnected, subject to the same bounded capacity and expiry.
- When retention capacity is full of active clients, an overflow client may receive live
  events without a replay buffer; later promotion preserves its sequence and watermark
  state rather than resetting or duplicating visible sequences.
- With `maxClients: 0`, active clients still share monotonic append/snapshot sequences and
  watermarks, but retain no replay history; after final disconnect, reconnect starts a new
  sequence window and an older cursor is outside that window.
- Replay frames are queued before live events, preserving sequence order across reconnect.
- Multiple sockets sharing one logical client receive the same broadcast envelope and
  sequence; project membership is reference-counted by socket, so one socket leaving does
  not detach a project still joined by another.
- A connection-local join snapshot consumes a visible sequence but records a replay
  watermark, so disconnecting immediately after the snapshot and resuming from that cursor
  is an exact caught-up replay rather than `replayUnavailable`.
- Complete framed writes are serialized at the transport boundary, including concurrent app
  sends.
- Replay stores run periodic expiry cleanup while the daemon is idle; expiry does not
  require a subsequent append or reconnect attempt.
- Responses and errors are not replayed. They are correlated to the request that produced
  them, while subscription events remain sequenced.
- A rejected graph command returns its correlated error and never a successful response
  snapshot.
- A successful mutation with no response payload returns a correlated response envelope
  with `success: true`.
- A reconnect never silently treats an unrelated event as command acknowledgement.

## Test fixtures

- Frozen current Swift CLI command.
- Frozen current macOS app command/event exchange.
- Frozen delivered Python remote-shim command.
- Interleaved v2 requests and events.
- Unsupported version, malformed envelope, partial/oversized frame, timeout, and reconnect.
