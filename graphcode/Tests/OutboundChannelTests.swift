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

  /// One connection joins as many projects as it likes, and every project's store writes
  /// to that one socket. Keying supersession on the event name alone let the newest
  /// snapshot displace a *different* project's undelivered one, so a client that had just
  /// joined two projects silently never received the first.
  @Test
  func snapshotsOfDifferentGraphsDoNotSupersedeEachOther() {
    let (daemon, client) = makeSocketPair()
    OutboundChannels.open(daemon)
    defer {
      OutboundChannels.close(daemon)
      close(client)
    }

    let projectA = makeFrame("project-a")
    let projectB = makeFrame("project-b")
    OutboundChannels.send(projectA, to: daemon, supersedingKey: "graphChanged:A")
    OutboundChannels.send(projectB, to: daemon, supersedingKey: "graphChanged:B")

    var received: [Data] = []
    while let frame = try? FramedMessageIO.readFrame(from: client) {
      received.append(frame)
      if received.count == 2 { break }
    }

    #expect(received.contains(projectA), "project A's snapshot was superseded by project B's")
    #expect(received.contains(projectB))
  }

  /// The budget exists for a *backlog*, not for one big frame. Measuring the whole queue
  /// meant a single oversized snapshot tripped the valve on its own and disconnected a
  /// healthy reader — and the bigger a graph grew, the more certain it became that nobody
  /// could open it.
  @Test
  func oneOversizedFrameIsDeliveredRatherThanDroppedAsABacklog() {
    let (daemon, client) = makeSocketPair()
    OutboundChannels.open(daemon)
    defer {
      OutboundChannels.close(daemon)
      close(client)
    }

    let huge = makeFrame("huge", bytes: OutboundChannel.maxBacklogBytes + 512 * 1024)
    #expect(OutboundChannels.send(huge, to: daemon))
    let delivered = try? FramedMessageIO.readFrame(from: client)
    #expect(delivered == huge)
  }

  /// Descriptor numbers are recycled, so a send arriving after its connection closed must
  /// not mint a channel on a number the kernel has already reassigned — that hands the
  /// departed connection's frame to whoever holds it now.
  @Test
  func aSendToAnUnregisteredDescriptorIsRefusedRatherThanDelivered() {
    let (daemon, client) = makeSocketPair()
    defer {
      close(daemon)
      close(client)
    }

    // Never opened, so nothing may be written to it — this is also the signal a
    // broadcaster uses to forget a connection that has gone.
    #expect(OutboundChannels.send(makeFrame("stray"), to: daemon) == false)
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

  /// Closing must not wait on a peer that has stopped reading — a writer parked inside
  /// `write(2)` will not notice a flag, so the channel tears the socket down to make that
  /// call return. Without that, disconnecting a wedged client would hang the connection
  /// loop instead of the actor: the same bug, moved.
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

  /// The safety valve. With superseding in play a backlog is normally one snapshot, so
  /// reaching the budget means a peer stopped reading and stayed stopped across many
  /// distinct frames. Dropping it is the honest outcome, and `send` says so by returning
  /// false — which is what tells `GraphStore` to forget the connection.
  @Test
  func aClientThatNeverDrainsIsEventuallyDropped() {
    let (daemon, client) = makeSocketPair()
    OutboundChannels.open(daemon)
    defer {
      OutboundChannels.close(daemon)
      close(client)
    }

    // Unkeyed, so nothing collapses and the backlog genuinely grows past its budget.
    let frame = makeFrame("flood", bytes: 512 * 1024)
    let budgetedFrames = OutboundChannel.maxBacklogBytes / frame.count
    var refusedAt: Int?
    for index in 0...(budgetedFrames + 4) where refusedAt == nil {
      if !OutboundChannels.send(frame, to: daemon) { refusedAt = index }
    }

    #expect(refusedAt != nil, "a client that never drains was never dropped")
  }
}
