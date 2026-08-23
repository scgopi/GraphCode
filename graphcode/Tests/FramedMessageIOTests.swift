import Foundation
import Testing

@testable import GraphcodeKit

/// Framing over a socket, and the property the whole protocol rests on: a frame written
/// while another frame is being written to the same connection must not interleave with
/// it.
@Suite
struct FramedMessageIOTests {
  /// Creates a connected pair of sockets, standing in for a client and `graphcoded`.
  private func makeSocketPair() -> (Int32, Int32) {
    var descriptors: [Int32] = [0, 0]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
    return (descriptors[0], descriptors[1])
  }

  @Test
  func aFrameSurvivesTheRoundTrip() throws {
    let (writer, reader) = makeSocketPair()
    defer {
      close(writer)
      close(reader)
    }

    let payload = Data("{\"command\":\"listRecentProjects\"}".utf8)
    try FramedMessageIO.writeFrame(payload, to: writer)
    #expect(try FramedMessageIO.readFrame(from: reader) == payload)
  }

  @Test
  func concurrentWritersDoNotInterleaveTheirFrames() throws {
    // The 0.1.46-beta1 bug, reproduced. A frame goes out as two writes — a 4-byte length
    // header, then the body — and `AppFeature`'s launch effect sends three commands at
    // once, each hopping onto the global queue. Interleave two of those and the daemon
    // reads header A followed by body B, fails to decode it, and answers "unrecognized
    // command — graphcoded may be older than the client that sent it". Nothing is out of
    // date; the bytes were spliced.
    //
    // It showed up on a *new workspace* because the three sends pile up behind the
    // connect retry while the just-bootstrapped daemon comes up, then resume together.
    //
    // Bodies are far larger than a socket buffer so a single write cannot complete in one
    // syscall — that makes the interleaving certain rather than occasional, which is what
    // a regression test needs.
    let (writer, reader) = makeSocketPair()
    defer {
      close(writer)
      close(reader)
    }

    let writerCount = 8
    let bodySize = 64 * 1024
    let payloads = (0..<writerCount).map { index in
      Data(("\(index):" + String(repeating: "\(index)", count: bodySize)).utf8)
    }

    // The reader has to run alongside the writers: the socket buffer is a few kilobytes,
    // so nobody finishes writing until somebody starts draining.
    let received = Mutex<[Data]>([])
    let readerFinished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      for _ in 0..<writerCount {
        guard let frame = try? FramedMessageIO.readFrame(from: reader) else { break }
        received.withLock { $0.append(frame) }
      }
      readerFinished.signal()
    }

    DispatchQueue.concurrentPerform(iterations: writerCount) { index in
      try? FramedMessageIO.writeFrame(payloads[index], to: writer)
    }

    #expect(readerFinished.wait(timeout: .now() + 30) == .success)

    // Every frame arrives whole, and each is one of the payloads — a spliced frame fails
    // both halves of that: the wrong length is read, and the bytes belong to two writers.
    let frames = received.withLock { $0 }
    #expect(frames.count == writerCount)
    #expect(Set(frames) == Set(payloads))
  }
}

/// A minimal lock box, so the reader thread can hand its frames back without the test
/// needing an actor (and the `await` that would come with one).
private final class Mutex<Value>: @unchecked Sendable {
  private var value: Value
  private let lock = NSLock()

  init(_ value: Value) { self.value = value }

  func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
    lock.lock()
    defer { lock.unlock() }
    return body(&value)
  }
}
