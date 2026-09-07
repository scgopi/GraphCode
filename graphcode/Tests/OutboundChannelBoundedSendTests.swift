import Foundation
import Testing

@testable import GraphcodeKit

#if canImport(Darwin)
  import Darwin
#endif

/// A writer on a peer that never reads must still return between slices, or closing
/// that connection hangs the caller — the promise #291 made for `closeAndWait`. On macOS
/// `MSG_DONTWAIT` does not keep it (the flag is ignored on a blocking unix socket); the
/// socket's send timeout does.
@Suite
struct OutboundChannelBoundedSendTests {
  private func deafPair() -> (daemon: Int32, peer: Int32) {
    var pair: [Int32] = [0, 0]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
    var small: Int32 = 4096
    setsockopt(pair[0], SOL_SOCKET, SO_SNDBUF, &small, socklen_t(MemoryLayout<Int32>.size))
    setsockopt(pair[1], SOL_SOCKET, SO_RCVBUF, &small, socklen_t(MemoryLayout<Int32>.size))
    return (pair[0], pair[1])
  }

  /// `closeAndWait` after `shutdown` is bounded either way — `shutdown` wakes a send
  /// parked on a unix socket. The path that cannot shut the socket down is `detach`,
  /// for a descriptor number a new connection has already taken over: there the writer
  /// must notice `isClosing` between slices on its own, and a writer parked inside
  /// `send(2)` never does. Without the send timeout this waits for the peer's lifetime.
  @Test
  func aDetachedWriterWedgedOnADeafPeerRetiresWithinABoundedTime() async throws {
    let (daemon, peer) = deafPair()
    defer {
      close(daemon)
      close(peer)
    }
    let channel = OutboundChannel(fileDescriptor: daemon)
    #expect(channel.send(Data(repeating: 0x78, count: 60_000)))
    // Let the writer fill the peer and park.
    try await Task.sleep(for: .milliseconds(300))

    let started = Date()
    let retired = Task.detached {
      channel.detach()
      channel.closeAndWait()
    }
    let outcome = await withTaskGroup(of: Bool.self) { group in
      group.addTask {
        await retired.value
        return true
      }
      group.addTask {
        try? await Task.sleep(for: .seconds(3))
        return false
      }
      let first = await group.next() ?? false
      group.cancelAll()
      return first
    }
    #expect(outcome, "a detached writer did not retire within 3 s of a wedged peer")
    #expect(Date().timeIntervalSince(started) < 3)
  }

  @Test
  func aSlowReaderStillGetsTheWholeFrame() async throws {
    let (daemon, peer) = deafPair()
    defer {
      OutboundChannels.close(daemon)
      close(peer)
    }
    OutboundChannels.open(daemon)
    let payload = Data(repeating: 0x79, count: 20_000)
    #expect(OutboundChannels.send(payload, to: daemon))
    // Drain slowly, off the writer's thread, and check the frame arrives intact.
    let received = await Task.detached { () -> Data? in
      try? await Task.sleep(for: .milliseconds(200))
      return try? FramedMessageIO.readFrame(from: peer)
    }.value
    #expect(received == payload)
  }
}
