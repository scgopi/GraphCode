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

  #if canImport(Darwin)
    @Test
    func syncReceiveRejectsUInt32MaximumBeforeAllocatingLegacyPayload() throws {
      var fds: [Int32] = [0, 0]
      #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
      defer {
        close(fds[0])
        close(fds[1])
      }

      let header = Data([0xff, 0xff, 0xff, 0xff])
      let written = header.withUnsafeBytes { rawBuffer in
        Darwin.write(fds[1], rawBuffer.baseAddress, rawBuffer.count)
      }
      #expect(written == header.count)

      let connection = UnixSocketConnection(fileDescriptor: fds[0])
      #expect(throws: FramedMessageIO.IOError.payloadTooLarge) {
        _ = try connection.receiveFrameSync()
      }
    }
  #endif

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
