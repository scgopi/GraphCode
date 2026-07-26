import Foundation
import GraphcodeKit
import Testing

@testable import graphcode

#if canImport(Darwin)
  import Darwin
#endif

/// `graphcoded` answers on the connection a command arrived on, so the app's one client
/// has to send and listen over the *same* socket. It didn't: `connect()` and
/// `send(.listRecentProjects)` start together in `AppFeature.task`, both raced past
/// `DaemonConnection`'s descriptor cache while the first connect was suspended, and each
/// opened its own socket — so every reply landed on the socket nobody read and the app
/// could never open a project. These tests pin the invariant against a stand-in daemon.
@Suite
struct OrchestratorClientTests {
  @Test
  func connectAndSendShareOneSocket() async throws {
    let daemon = try StubDaemon()
    defer { daemon.stop() }
    let client = OrchestratorClient.live(socketPath: daemon.socketPath)

    // The order `AppFeature.task` uses: subscribe and send, concurrently.
    let events = client.connect()
    async let received = firstEvent(of: events)
    try await client.send(.listRecentProjects)

    let command = try #require(await daemon.nextCommand())
    #expect(command == .listRecentProjects)

    let project = ProjectRef(path: "/tmp/stub-project", name: "stub-project")
    try daemon.reply(.recentProjectsListed([project]))
    #expect(await received == .recentProjectsListed([project]))

    // The whole point: the reply reached the subscriber because there is exactly one
    // socket. Two would have put it on the unread one.
    #expect(daemon.acceptedConnectionCount == 1)
  }

  @Test
  func connectRetriesUntilTheDaemonIsListening() async throws {
    // The app can launch before `graphcoded` finishes starting up, so a client created
    // against a socket that doesn't exist yet has to keep dialing.
    let socketPath = StubDaemon.temporarySocketPath()
    let client = OrchestratorClient.live(socketPath: socketPath)
    let events = client.connect()
    async let received = firstEvent(of: events)

    try await Task.sleep(for: .milliseconds(150))
    let daemon = try StubDaemon(socketPath: socketPath)
    defer { daemon.stop() }

    try daemon.reply(.errorOccurred("late but connected"))
    #expect(await received == .errorOccurred("late but connected"))
  }

  private func firstEvent(of events: AsyncStream<DaemonEvent>) async -> DaemonEvent? {
    for await event in events { return event }
    return nil
  }
}

/// A minimal stand-in for `graphcoded`: binds a socket in a temp directory, accepts
/// connections on a background thread, and lets the test read what was sent and write
/// events back over the connection it accepted.
private final class StubDaemon: @unchecked Sendable {
  enum StubError: Error, Equatable {
    case socketSetupFailed(step: String, errno: Int32)
    case noConnection
  }

  let socketPath: URL

  private let listenerDescriptor: Int32
  private let lock = NSLock()
  private var acceptedDescriptors: [Int32] = []
  private var stopped = false

  static func temporarySocketPath() -> URL {
    // Socket paths land in a `sockaddr_un.sun_path` of ~104 bytes, so this stays short
    // rather than nesting under the test bundle's own temp directory.
    URL(fileURLWithPath: "/tmp")
      .appendingPathComponent("gc-test-\(UUID().uuidString.prefix(8)).sock")
  }

  init(socketPath: URL = StubDaemon.temporarySocketPath()) throws {
    self.socketPath = socketPath
    try? FileManager.default.removeItem(at: socketPath)

    listenerDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard listenerDescriptor >= 0 else {
      throw StubError.socketSetupFailed(step: "socket", errno: errno)
    }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutablePointer(to: &address.sun_path) { pathField in
      pathField.withMemoryRebound(
        to: CChar.self, capacity: MemoryLayout.size(ofValue: pathField.pointee)
      ) { pathPointer in
        _ = socketPath.path.withCString { cPath in
          strncpy(pathPointer, cPath, MemoryLayout.size(ofValue: pathField.pointee) - 1)
        }
      }
    }

    let bindResult = withUnsafePointer(to: &address) { addressPointer -> Int32 in
      addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rawPointer in
        bind(listenerDescriptor, rawPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bindResult == 0 else { throw StubError.socketSetupFailed(step: "bind", errno: errno) }
    guard listen(listenerDescriptor, 8) == 0 else {
      throw StubError.socketSetupFailed(step: "listen", errno: errno)
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

  var acceptedConnectionCount: Int {
    lock.withLock { acceptedDescriptors.count }
  }

  /// Reads one framed command off the first accepted connection, waiting for the accept
  /// to land. Blocking reads run off the cooperative pool.
  func nextCommand() async -> DaemonCommand? {
    await withCheckedContinuation { continuation in
      DispatchQueue.global().async { [self] in
        guard let descriptor = waitForFirstConnection(),
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

  /// Writes an event back the way `graphcoded` does — on the accepted connection.
  func reply(_ event: DaemonEvent) throws {
    guard let descriptor = waitForFirstConnection() else { throw StubError.noConnection }
    try FramedMessageIO.writeFrame(try JSONEncoder().encode(event), to: descriptor)
  }

  func stop() {
    lock.withLock {
      guard !stopped else { return }
      stopped = true
      for descriptor in acceptedDescriptors { close(descriptor) }
      acceptedDescriptors = []
    }
    close(listenerDescriptor)
    try? FileManager.default.removeItem(at: socketPath)
  }

  private func waitForFirstConnection() -> Int32? {
    for _ in 0..<200 {
      if let descriptor = lock.withLock({ acceptedDescriptors.first }) { return descriptor }
      usleep(25_000)
    }
    return nil
  }
}
