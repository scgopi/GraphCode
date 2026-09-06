import Foundation
import GraphcodeKit
import MailroomKit
import Testing

@testable import graphcode

#if canImport(Darwin)
  import Darwin
#endif

/// Review probes for #296 (encode once) and #297 (presence deltas).
///
/// `nodesChanged` is the first event the daemon *broadcasts* unasked. Every other event
/// a client can meet is either one it already knew about or the answer to a command it
/// chose to send, so version skew on the event side has never been exercised. These pin
/// what an app one release behind actually does when a newer daemon speaks to it.
@Suite
struct BroadcastDeltaReviewTests {
  private static let project = ProjectRef(path: "/tmp/review-delta", name: "review-delta")

  /// `DaemonEvent` as the shipped 0.1.63 app knows it — before `nodesChanged` existed.
  private enum LegacyDaemonEvent: Codable {
    case graphChanged(LoopGraph)
    case errorOccurred(String)
    case recentProjectsListed([ProjectRef])
    case mailbox(projectPath: String, mailbox: Mailbox)
  }

  /// A presence delta is not merely ignored by an older client — it is undecodable.
  /// Swift's synthesised enum coding rejects a case key it has never heard of, so the
  /// frame throws rather than arriving as something to skip.
  @Test
  func anOlderClientCannotDecodeAPresenceDelta() throws {
    let node = LoopNode(title: "Moving", loopType: .goalBased, goal: GoalSpec(summary: "done"))
    let frame = try JSONEncoder().encode(
      DaemonEvent.nodesChanged(projectPath: Self.project.path, revision: 7, nodes: [node]))
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(LegacyDaemonEvent.self, from: frame)
    }
  }

  /// And the app's event stream treats an undecodable frame exactly as it treats a dead
  /// socket: it invalidates the connection and dials again. The daemon already refuses to
  /// do this in the mirror case — `graphcoded`'s command loop answers version skew with
  /// an `errorOccurred` rather than hanging up, because hanging up "failed *silently*".
  /// The client half has no such handling, so a 0.1.63 app on a daemon that ships #297
  /// tears its socket down and re-joins every project on every presence tick — four times
  /// a minute, for as long as the two are mismatched.
  @Test
  func aFrameTheClientCannotDecodeDoesNotTearDownTheConnection() async throws {
    let daemon = try ReviewStubDaemon()
    defer { daemon.stop() }
    let client = OrchestratorClient.live(socketPath: daemon.socketPath)

    let events = client.connect()
    let reader = Task { for await _ in events {} }
    defer { reader.cancel() }
    try await client.send(.listRecentProjects)
    _ = try #require(await daemon.nextCommand())
    #expect(daemon.acceptedConnectionCount == 1)

    // A daemon one release ahead broadcasts an event this app has never heard of.
    try daemon.writeRawFrame(Data(#"{"somethingThisAppPredates":{"revision":7}}"#.utf8))

    // Long enough to cover the one-second backoff a dropped connection retries on.
    try await Task.sleep(for: .seconds(3))

    // The frame it could not read is not a reason to hang up: one socket, not two.
    #expect(daemon.acceptedConnectionCount == 1)
  }

}

/// A stand-in `graphcoded` that can also write a frame the app's `DaemonEvent` cannot
/// decode — the one thing `OrchestratorClientTests`' own stub has no way to express.
private final class ReviewStubDaemon: @unchecked Sendable {
  enum StubError: Error { case setupFailed(step: String, errno: Int32), noConnection }

  let socketPath: URL
  private let listenerDescriptor: Int32
  private let lock = NSLock()
  private var acceptedDescriptors: [Int32] = []

  init() throws {
    socketPath = URL(fileURLWithPath: "/tmp")
      .appendingPathComponent("gc-review-\(UUID().uuidString.prefix(8)).sock")
    try? FileManager.default.removeItem(at: socketPath)
    listenerDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard listenerDescriptor >= 0 else { throw StubError.setupFailed(step: "socket", errno: errno) }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutablePointer(to: &address.sun_path) { pathField in
      pathField.withMemoryRebound(
        to: CChar.self, capacity: MemoryLayout.size(ofValue: pathField.pointee)
      ) { pathPointer in
        _ = socketPath.path.withCString { strncpy(pathPointer, $0, 103) }
      }
    }
    let bound = withUnsafePointer(to: &address) { pointer -> Int32 in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(listenerDescriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bound == 0 else { throw StubError.setupFailed(step: "bind", errno: errno) }
    guard listen(listenerDescriptor, 8) == 0 else {
      throw StubError.setupFailed(step: "listen", errno: errno)
    }

    let listener = listenerDescriptor
    let acceptLoop = Thread { [weak self] in
      while true {
        let descriptor = accept(listener, nil, nil)
        guard descriptor >= 0, let self else { return }
        self.lock.withLock { self.acceptedDescriptors.append(descriptor) }
      }
    }
    acceptLoop.start()
  }

  var acceptedConnectionCount: Int { lock.withLock { acceptedDescriptors.count } }

  func nextCommand(onConnection index: Int = 0) async -> DaemonCommand? {
    await withCheckedContinuation { continuation in
      DispatchQueue.global().async { [self] in
        guard let descriptor = waitForConnection(at: index),
          let data = try? FramedMessageIO.readFrame(from: descriptor),
          let command = try? JSONDecoder().decode(DaemonCommand.self, from: data)
        else {
          continuation.resume(returning: nil)
          return
        }
        continuation.resume(returning: command)
      }
    }
  }

  func writeRawFrame(_ payload: Data, onConnection index: Int = 0) throws {
    guard let descriptor = waitForConnection(at: index) else { throw StubError.noConnection }
    try FramedMessageIO.writeFrame(payload, to: descriptor)
  }

  func stop() {
    lock.withLock {
      for descriptor in acceptedDescriptors where descriptor >= 0 { close(descriptor) }
      acceptedDescriptors = []
    }
    close(listenerDescriptor)
    try? FileManager.default.removeItem(at: socketPath)
  }

  private func waitForConnection(at index: Int) -> Int32? {
    for _ in 0..<200 {
      let descriptor = lock.withLock {
        acceptedDescriptors.indices.contains(index) ? acceptedDescriptors[index] : nil
      }
      if let descriptor, descriptor >= 0 { return descriptor }
      usleep(25_000)
    }
    return nil
  }
}
