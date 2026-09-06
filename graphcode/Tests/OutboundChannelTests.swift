import Foundation
import Testing

@testable import GraphcodeKit

/// The daemon's outbound half, and the property issue #288 was the absence of: handing a
/// frame to a client must not make the caller wait for that client to read it.
@Suite
struct OutboundChannelTests {
  private func makeSocketPair() -> (daemon: Int32, client: Int32) {
    var descriptors: [Int32] = [0, 0]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
    return (descriptors[0], descriptors[1])
  }

  /// Comfortably past `SO_SNDBUF`, which is 8 KB on these sockets — the whole point is a
  /// frame that cannot be handed to the kernel in one go, which is what a `graphChanged`
  /// snapshot is at 176 KB.
  private func makeFrame(_ marker: String, bytes: Int = 200 * 1024) -> Data {
    Data((marker + ":" + String(repeating: "x", count: bytes)).utf8)
  }

  private func readFrames(_ count: Int, from descriptor: Int32) -> [Data] {
    var frames: [Data] = []
    for _ in 0..<count {
      guard let frame = try? FramedMessageIO.readFrame(from: descriptor) else { break }
      frames.append(frame)
    }
    return frames
  }

  /// Issue #288, reproduced at the layer that caused it.
  ///
  /// A client connects and then stops reading — exactly what the `graphcode` CLI does
  /// while it renders its output, holding its connection open the whole time. Before the
  /// channel, the blocking `write` behind this call was performed by the `GraphStore`
  /// actor itself, so it parked there until the client resumed and every other command
  /// for that project queued behind it. Sending must now cost the caller nothing.
  @Test
  func sendingToAClientThatNeverReadsDoesNotBlockTheCaller() {
    let (daemon, client) = makeSocketPair()
    OutboundChannels.open(daemon)
    defer {
      OutboundChannels.close(daemon)
      close(client)
    }

    // Far more than any socket buffer could absorb, to a peer that reads none of it.
    let started = Date()
    for index in 0..<12 {
      OutboundChannels.send(makeFrame("frame-\(index)"), to: daemon)
    }
    let elapsed = Date().timeIntervalSince(started)

    // Generous: the point is the difference between "returns" and "waits for a reader",
    // not a benchmark. Blocking writes would not get past the second frame.
    #expect(elapsed < 2.0, "sending to a non-draining client took \(elapsed)s")
  }

  @Test
  func framesArriveIntactAndInOrder() throws {
    let (daemon, client) = makeSocketPair()
    OutboundChannels.open(daemon)
    defer {
      OutboundChannels.close(daemon)
      close(client)
    }

    let sent = (0..<4).map { makeFrame("ordered-\($0)", bytes: 32 * 1024) }
    // No superseding key: these are the unicast replies that each have to arrive.
    for frame in sent { OutboundChannels.send(frame, to: daemon) }

    #expect(readFrames(sent.count, from: client) == sent)
  }

  /// Why `graphChanged` passes a superseding key. The event carries the entire graph and
  /// never a diff, so a snapshot still queued behind a slow client is worthless the moment
  /// a newer one exists — a client that fell behind should be caught up, not walked
  /// through every state the graph passed through while it was not reading.
  @Test
  func anUndeliveredSnapshotIsSupersededRatherThanQueuedBehind() {
    let (daemon, client) = makeSocketPair()
    OutboundChannels.open(daemon)
    defer {
      OutboundChannels.close(daemon)
      close(client)
    }

    let markers = ["first", "second", "third", "fourth", "newest"]
    for marker in markers {
      OutboundChannels.send(makeFrame(marker), to: daemon, supersedingKey: "graphChanged")
    }

    // Whichever frame the writer had already started is in flight and will arrive; the
    // rest collapse into the newest. So: strictly fewer than were sent, ending at the
    // newest — never a middle state, which is the property that matters.
    var received: [Data] = []
    while let frame = try? FramedMessageIO.readFrame(from: client) {
      received.append(frame)
      if frame == makeFrame("newest") { break }
    }

    #expect(received.count < markers.count)
    #expect(received.last == makeFrame("newest"))
    #expect(!received.contains(makeFrame("second")))
  }

  /// A frame sent under one key must not displace traffic under another — an
  /// `errorOccurred` answering a command has to arrive even while snapshots collapse.
  @Test
  func supersedingOneKeyLeavesUnkeyedFramesAlone() {
    let (daemon, client) = makeSocketPair()
    OutboundChannels.open(daemon)
    defer {
      OutboundChannels.close(daemon)
      close(client)
    }

    let reply = makeFrame("the-error-reply", bytes: 1024)
    OutboundChannels.send(makeFrame("snapshot-old"), to: daemon, supersedingKey: "graphChanged")
    OutboundChannels.send(reply, to: daemon)
    OutboundChannels.send(makeFrame("snapshot-new"), to: daemon, supersedingKey: "graphChanged")

    var received: [Data] = []
    while let frame = try? FramedMessageIO.readFrame(from: client) {
      received.append(frame)
      if frame == makeFrame("snapshot-new") { break }
    }

    #expect(received.contains(reply))
  }

  /// Closing must not wait on a peer that has stopped reading. This is why no single send
  /// may park indefinitely: a thread already blocked inside one is not reliably woken by
  /// another thread's `shutdown`, so a wedged peer could hang the disconnecting caller for
  /// ever — the original bug moved one layer down, from the actor to the connection loop.
  /// Coming back every `SO_SNDTIMEO` slice lets the writer notice the close by itself.
  @Test
  func closingReleasesAWriterParkedOnAWedgedClient() {
    let (daemon, client) = makeSocketPair()
    OutboundChannels.open(daemon)

    for index in 0..<8 {
      OutboundChannels.send(makeFrame("wedged-\(index)"), to: daemon)
    }

    let started = Date()
    OutboundChannels.close(daemon)
    let elapsed = Date().timeIntervalSince(started)
    close(client)

    #expect(elapsed < 2.0, "closing a wedged channel took \(elapsed)s")
  }

  /// The correction to #291. `MSG_DONTWAIT` does nothing for `send` on a blocking
  /// AF_UNIX stream socket on macOS — measured at 60 KB into a 4 KB peer, still inside
  /// the syscall after two minutes — so the writer parked there and the poll loop that
  /// `closeAndWait` depends on never ran. `SO_SNDTIMEO` is what actually bounds it, and
  /// it has to be on the descriptor before anything is written.
  @Test
  func theChannelBoundsHowLongOneSendMayPark() {
    let (daemon, client) = makeSocketPair()
    OutboundChannels.open(daemon)
    defer {
      OutboundChannels.close(daemon)
      close(client)
    }

    var timeout = timeval(tv_sec: 0, tv_usec: 0)
    var size = socklen_t(MemoryLayout<timeval>.size)
    #expect(getsockopt(daemon, SOL_SOCKET, SO_SNDTIMEO, &timeout, &size) == 0)

    let microseconds = Int(timeout.tv_sec) * 1_000_000 + Int(timeout.tv_usec)
    #expect(microseconds > 0, "a send on this channel is unbounded")
    // Bounded, and short enough that a close is noticed promptly rather than a slice
    // later — anything approaching a second would put the teardown back where it was.
    #expect(microseconds <= 200_000)
  }

  /// The safety valve. With superseding in play a backlog is normally one snapshot, so
  /// reaching the budget means a peer stopped reading and stayed stopped across many
  /// distinct frames. Dropping it is the honest outcome, and `send` says so by returning
  /// false — which is what tells `GraphStore` to forget the connection.
  @Test
  func aClientThatNeverDrainsIsEventuallyDropped() {
    // A small injected budget, so the valve can be reached without shifting the real
    // four megabytes through a socket on every run of the suite.
    let budget = 64 * 1024
    let (daemon, client) = makeSocketPair()
    OutboundChannels.open(daemon, backlogBudget: budget)
    defer {
      OutboundChannels.close(daemon)
      close(client)
    }

    // Unkeyed, so nothing collapses and the backlog genuinely grows past its budget.
    let frame = makeFrame("flood", bytes: 16 * 1024)
    var refusedAt: Int?
    for index in 0...(budget / frame.count + 6) where refusedAt == nil {
      if !OutboundChannels.send(frame, to: daemon) { refusedAt = index }
    }

    #expect(refusedAt != nil, "a client that never drains was never dropped")
  }
}
