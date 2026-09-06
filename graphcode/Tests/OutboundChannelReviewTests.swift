import Foundation
import Testing

@testable import GraphcodeKit

/// Review probes for PR #291 — each one is a sequence the channel should survive.
@Suite
struct OutboundChannelReviewTests {
  private func makeSocketPair() -> (daemon: Int32, client: Int32) {
    var descriptors: [Int32] = [0, 0]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
    return (descriptors[0], descriptors[1])
  }

  private func frame(_ marker: String, bytes: Int = 200 * 1024) -> Data {
    Data((marker + ":" + String(repeating: "x", count: bytes)).utf8)
  }

  /// A sidebar connection is joined to every open project over one descriptor
  /// (`ProjectRegistry.joinSidebars`), and every store keys its snapshot "graphChanged".
  /// While the writer is parked on a frame the client has not drained, project B's
  /// snapshot displaces project A's — and the client stays stale on A until A changes
  /// again, which may be never.
  @Test
  func snapshotsFromDifferentProjectsMustNotSupersedeEachOther() async throws {
    let (daemon, client) = makeSocketPair()
    OutboundChannels.open(daemon)
    defer {
      OutboundChannels.close(daemon)
      close(client)
    }

    OutboundChannels.send(frame("parked"), to: daemon)

    let storeA = GraphStore(
      graph: LoopGraph(project: ProjectRef(path: "/tmp/review/a", name: "a")))
    let storeB = GraphStore(
      graph: LoopGraph(project: ProjectRef(path: "/tmp/review/b", name: "b")))
    let sidebar = UUID()
    await storeA.addConnection(id: sidebar, fileDescriptor: daemon)
    await storeB.addConnection(id: sidebar, fileDescriptor: daemon)
    let sentinel = frame("sentinel", bytes: 16)
    OutboundChannels.send(sentinel, to: daemon)

    var delivered: [String] = []
    while let data = try? FramedMessageIO.readFrame(from: client) {
      if data == sentinel { break }
      if let event = try? JSONDecoder().decode(DaemonEvent.self, from: data),
        case .graphChanged(let graph) = event
      {
        delivered.append(graph.project.path)
      }
    }
    #expect(
      delivered.contains("/tmp/review/a"),
      "project A's snapshot was superseded by project B's; delivered: \(delivered)")
    #expect(delivered.contains("/tmp/review/b"))
  }

  /// `send` opens a channel for a descriptor nobody registered. Descriptor numbers are
  /// recycled the moment they close, and a broadcaster still holding the old number —
  /// `GraphStore` forgets a connection only on its *next* refused send — writes into
  /// whichever connection owns that number now.
  @Test
  func aStaleSendMustNotBindAChannelToTheNextOwnerOfTheDescriptor() throws {
    let (old, oldPeer) = makeSocketPair()
    OutboundChannels.open(old)
    OutboundChannels.close(old)
    close(oldPeer)

    let (fresh, freshPeer) = makeSocketPair()
    if fresh != old {
      #expect(dup2(fresh, old) == old)
      close(fresh)
    }
    defer {
      OutboundChannels.close(old)
      close(freshPeer)
    }

    let stale = frame("from-a-connection-that-is-gone", bytes: 64)
    let intended = frame("meant-for-the-new-connection", bytes: 64)
    let accepted = OutboundChannels.send(stale, to: old)
    OutboundChannels.open(old)
    OutboundChannels.send(intended, to: old)

    #expect(!accepted, "a send to an unregistered descriptor was accepted")
    let first = try FramedMessageIO.readFrame(from: freshPeer)
    #expect(first == intended, "the new connection received a frame meant for the old one")
  }

  /// The valve counts the frame it just appended, so one snapshot larger than the budget
  /// trips it on a queue of one. Every client would then be dropped on the broadcast it
  /// joined for, and the daemon would have no client left it can serve.
  @Test
  func oneFrameLargerThanTheBudgetIsNotABacklog() throws {
    let (daemon, client) = makeSocketPair()
    OutboundChannels.open(daemon)
    defer {
      OutboundChannels.close(daemon)
      close(client)
    }

    let snapshot = frame("one-big-snapshot", bytes: OutboundChannel.maxBacklogBytes + 1)
    OutboundChannels.send(snapshot, to: daemon)

    let received = try FramedMessageIO.readFrame(from: client)
    #expect(received == snapshot)
  }

  /// Close racing sends from several threads, with the freed number recycled straight
  /// into the next pair, over and over. Anything wrong in the close/shutdown ordering —
  /// a `closeAndWait` that never returns, a write on a number that already belongs to
  /// the next connection, a use of a closed descriptor — shows up as a hang or a crash.
  @Test
  func concurrentSendsAndClosesWithRecycledDescriptorsNeverHang() {
    let started = Date()
    for round in 0..<150 {
      let (daemon, client) = makeSocketPair()
      OutboundChannels.open(daemon)
      let senders = DispatchGroup()
      for lane in 0..<4 {
        DispatchQueue.global().async(group: senders) {
          for index in 0..<8 {
            OutboundChannels.send(
              self.frame("r\(round)-l\(lane)-\(index)", bytes: 64 * 1024), to: daemon,
              supersedingKey: index % 2 == 0 ? "graphChanged" : nil)
          }
        }
      }
      if round % 3 == 0 { _ = try? FramedMessageIO.readFrame(from: client) }
      OutboundChannels.close(daemon)
      senders.wait()
      close(client)
    }
    let elapsed = Date().timeIntervalSince(started)
    #expect(elapsed < 20, "150 rounds of open/send/close took \(elapsed)s")
  }

  /// The writer now hands the kernel whatever it will take per call and resumes from
  /// where it stopped. Every partial write must resume at the right byte and nothing may
  /// be sent twice: a peer that drains in small gulps, with a receive buffer far smaller
  /// than any frame, must reassemble every frame intact and in order.
  @Test
  func partialWritesResumeWithoutTruncatingOrDuplicating() throws {
    let (daemon, client) = makeSocketPair()
    var tiny: Int32 = 2048
    setsockopt(client, SOL_SOCKET, SO_RCVBUF, &tiny, socklen_t(MemoryLayout<Int32>.size))
    setsockopt(daemon, SOL_SOCKET, SO_SNDBUF, &tiny, socklen_t(MemoryLayout<Int32>.size))
    OutboundChannels.open(daemon)
    defer {
      OutboundChannels.close(daemon)
      close(client)
    }

    let sizes = [1, 3, 2047, 2048, 2049, 4095, 8191, 8192, 100_000, 7, 65_537, 300_000, 2]
    let sent = sizes.enumerated().map { index, size in
      Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &+ index) })
    }
    for frame in sent { OutboundChannels.send(frame, to: daemon) }

    var received: [Data] = []
    for _ in sent {
      received.append(try FramedMessageIO.readFrame(from: client))
      usleep(2_000)
    }
    #expect(received == sent)
  }

  /// A close landing mid-frame may truncate that frame, but the peer must then see the
  /// connection end — never a truncated frame followed by more bytes it could mistake for
  /// the next frame's header.
  @Test
  func aCloseMidFrameEndsTheStreamRatherThanCorruptingIt() {
    let (daemon, client) = makeSocketPair()
    OutboundChannels.open(daemon)
    OutboundChannels.send(frame("in-flight"), to: daemon)
    OutboundChannels.send(frame("queued-behind"), to: daemon)
    usleep(20_000)
    OutboundChannels.close(daemon)
    defer { close(client) }

    var complete: [Data] = []
    var ended = false
    while true {
      do {
        complete.append(try FramedMessageIO.readFrame(from: client))
      } catch {
        ended = true
        break
      }
    }
    #expect(ended)
    #expect(complete.allSatisfy { $0 == frame("in-flight") || $0 == frame("queued-behind") })
  }

  /// The peer vanishes while the writer is parked waiting for room. The channel must
  /// notice on its own — `poll` reporting the hang-up or the next `send` failing — and
  /// report the connection dead to the next broadcaster, without anyone closing it.
  @Test
  func aPeerThatVanishesWhileTheWriterIsParkedIsNoticedWithoutAClose() {
    let (daemon, client) = makeSocketPair()
    OutboundChannels.open(daemon)
    defer { OutboundChannels.close(daemon) }

    for index in 0..<4 { OutboundChannels.send(frame("parked-\(index)"), to: daemon) }
    usleep(20_000)
    close(client)

    let deadline = Date().addingTimeInterval(2)
    var refused = false
    while Date() < deadline && !refused {
      refused = !OutboundChannels.send(frame("after", bytes: 16), to: daemon)
      usleep(10_000)
    }
    #expect(refused, "the channel never noticed its peer had gone")
  }
}
