import Foundation
import Testing

@testable import GraphcodeKit

#if canImport(Darwin)
  import Darwin
#endif

/// The daemon has no request/response correlation, so a client says what it's waiting for
/// and reads until it arrives. The failure mode that creates — waiting on an event nothing
/// will ever cause — used to hang the CLI forever with no output. These pin the bound that
/// turns it into an error.
@Suite
struct DaemonSocketClientTests {
  /// Returns (client end, the other end the "daemon" writes into).
  private func makePair(timeout: TimeInterval) -> (DaemonSocketClient, Int32) {
    var fds: [Int32] = [0, 0]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
    return (DaemonSocketClient(fileDescriptor: fds[0], timeout: timeout), fds[1])
  }

  @Test
  func waitingForAnEventTheDaemonNeverSendsTimesOut() throws {
    // Nothing is ever written to the far end — exactly the shape of the `status` hang,
    // where the CLI awaited an acknowledgement its own (empty) command list couldn't
    // have caused.
    let (client, farEnd) = makePair(timeout: 0.3)
    defer {
      client.closeConnection()
      close(farEnd)
    }

    let started = Date()
    #expect(throws: DaemonSocketClient.ClientError.timedOut) {
      _ = try client.waitForEvent { _ in true }
    }
    // Bounded, and bounded by roughly what was asked for rather than some other limit.
    #expect(Date().timeIntervalSince(started) < 3)
  }

  @Test
  func anEventThatArrivesInTimeIsStillReturned() throws {
    // The timeout must not cost correctness on the normal path.
    let (client, farEnd) = makePair(timeout: 5)
    defer {
      client.closeConnection()
      close(farEnd)
    }

    let graph = LoopGraph(project: ProjectRef(path: "/tmp/p", name: "p"))
    try FramedMessageIO.writeFrame(
      try JSONEncoder().encode(DaemonEvent.graphChanged(graph)), to: farEnd)

    let event = try client.waitForEvent {
      if case .graphChanged = $0 { return true } else { return false }
    }
    guard case .graphChanged(let received) = event else {
      Issue.record("expected graphChanged, got \(String(describing: event))")
      return
    }
    #expect(received.project.path == "/tmp/p")
  }

  @Test
  func eventsThatDontMatchAreSkippedRatherThanMistakenForTheAnswer() throws {
    // Why `status` appeared to work on a busy project: an unrelated broadcast arrived and
    // was taken for the acknowledgement. A predicate that rejects it must keep reading.
    let (client, farEnd) = makePair(timeout: 5)
    defer {
      client.closeConnection()
      close(farEnd)
    }

    try FramedMessageIO.writeFrame(
      try JSONEncoder().encode(DaemonEvent.errorOccurred("unrelated")), to: farEnd)
    let graph = LoopGraph(project: ProjectRef(path: "/tmp/wanted", name: "wanted"))
    try FramedMessageIO.writeFrame(
      try JSONEncoder().encode(DaemonEvent.graphChanged(graph)), to: farEnd)

    let event = try client.waitForEvent {
      if case .graphChanged = $0 { return true } else { return false }
    }
    guard case .graphChanged(let received) = event else {
      Issue.record("expected graphChanged, got \(String(describing: event))")
      return
    }
    #expect(received.project.path == "/tmp/wanted")
  }

  /// Dialling is retried; anything after the first write is not. Nothing has been sent when
  /// a dial fails, so a redial cannot duplicate a mutation — whereas `node create`, `node
  /// send` and `node memo` are not idempotent, which is why a mid-exchange
  /// `connectionClosed` must stay off this list however transient it looks.
  @Test
  func onlyPreWriteFailuresAreWorthRedialing() {
    #expect(DaemonSocketClient.isTransient(DaemonSocketClient.ClientError.daemonNotRunning))
    #expect(
      DaemonSocketClient.isTransient(
        DaemonSocketClient.ClientError.connectionFailed(errno: ECONNREFUSED)))
    #expect(
      DaemonSocketClient.isTransient(DaemonSocketClient.ClientError.connectionFailed(errno: ENOENT))
    )

    #expect(
      !DaemonSocketClient.isTransient(
        DaemonSocketClient.ClientError.connectionFailed(errno: EACCES))
    )
    #expect(!DaemonSocketClient.isTransient(DaemonSocketClient.ClientError.timedOut))
    #expect(!DaemonSocketClient.isTransient(FramedMessageIO.IOError.connectionClosed))
  }
}

/// The contract the daemon's broadcast loop rests on: a write to a socket whose peer
/// has gone must come back as a *thrown error*, so `GraphStore.send` can drop the dead
/// connection. It is only an error if the process survives long enough to see it —
/// `graphcoded` ignores `SIGPIPE` and sets `SO_NOSIGPIPE` on every accepted socket for
/// exactly that reason, after the daemon was found dying with exit status -13 under a
/// client that stopped reading and then vanished. `scripts/daemon-sigpipe-probe.py`
/// reproduces that end to end against a built binary; this pins the layer below it.
@Suite
struct ClosedPeerWriteTests {
  @Test
  func writingToAClosedPeerThrowsRatherThanReportingSuccess() throws {
    var pair: [Int32] = [0, 0]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
    var enabled: Int32 = 1
    setsockopt(
      pair[0], SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
    close(pair[1])

    // Large enough that the write cannot vanish into a socket buffer that no longer
    // has a reader behind it.
    let payload = Data(repeating: 0x41, count: 256 * 1024)
    #expect(throws: FramedMessageIO.IOError.self) {
      try FramedMessageIO.writeFrame(payload, to: pair[0])
    }
    close(pair[0])
  }
}
