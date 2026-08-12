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
  #if canImport(Darwin)
    @Test
    func concurrentUnixSocketFramesRemainWhole() async throws {
      var descriptors = [Int32](repeating: 0, count: 2)
      guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
        throw OrchestratorClientError.connectFailed(errno: errno)
      }
      defer { close(descriptors[1]) }

      let sender = UnixSocketConnection(fileDescriptor: descriptors[0])
      let payloads = [
        Data(repeating: 0x41, count: 256 * 1024),
        Data(repeating: 0x42, count: 256 * 1024),
      ]
      let receiver = Task<[Data], Error> {
        try await withCheckedThrowingContinuation { continuation in
          DispatchQueue.global().async {
            do {
              continuation.resume(
                returning: [
                  try FramedMessageIO.readFrame(from: descriptors[1]),
                  try FramedMessageIO.readFrame(from: descriptors[1]),
                ])
            } catch {
              continuation.resume(throwing: error)
            }
          }
        }
      }

      try await withThrowingTaskGroup(of: Void.self) { group in
        for payload in payloads {
          group.addTask {
            try await sender.sendFrame(payload)
          }
        }
        try await group.waitForAll()
      }
      sender.closeSync()

      let received = try await receiver.value
      #expect(Set(received) == Set(payloads))
    }
  #endif

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

  @Test
  func cancellingBeforeConnectStopsRetrySleepAndFutureDial() async throws {
    let socketPath = StubDaemon.temporarySocketPath()
    let client = OrchestratorClient.live(socketPath: socketPath)
    let reader = Task {
      for await _ in client.connect() {}
    }

    try await Task.sleep(for: .milliseconds(100))
    reader.cancel()
    await reader.value

    let daemon = try StubDaemon(socketPath: socketPath)
    defer { daemon.stop() }
    try await Task.sleep(for: .milliseconds(500))
    #expect(daemon.acceptedConnectionCount == 0)
  }

  @Test
  func reconnectingRejoinsTheProjectsItHadOpen() async throws {
    // Joining is per-connection on the daemon's side, and the app asked to join once, from
    // `AppFeature.task`. So a client that lost its socket dialled again and was attached to
    // no `GraphStore` at all: commands still arrived and still took effect, but no
    // broadcast ever came back. Deleting a loop removed it from the daemon's graph and left
    // its row in the sidebar until the next relaunch.
    let daemon = try StubDaemon()
    defer { daemon.stop() }
    let client = OrchestratorClient.live(socketPath: daemon.socketPath)

    let events = client.connect()
    async let received = firstEvent(of: events)
    try await client.send(.listRecentProjects)
    let opening = try #require(await daemon.nextCommand())
    #expect(opening == .listRecentProjects)

    // The daemon hangs up, the way a restart does.
    daemon.closeConnection(at: 0)

    // The replacement socket announces itself instead of waiting to be spoken to.
    let rejoin = try #require(await daemon.nextCommand(onConnection: 1))
    #expect(rejoin == .restoreOpenProjects)
    let joinGlobal = try #require(await daemon.nextCommand(onConnection: 1))
    #expect(joinGlobal == .openGlobalGraph)

    // And it's a live subscription, not merely an open socket.
    try daemon.reply(.errorOccurred("after reconnect"), onConnection: 1)
    #expect(await received == .errorOccurred("after reconnect"))
  }

  @Test
  func cancellingAnEventStreamClosesItsReaderBeforeReconnect() async throws {
    let daemon = try StubDaemon()
    defer { daemon.stop() }
    let client = OrchestratorClient.live(socketPath: daemon.socketPath)

    let oldReader = Task {
      for await _ in client.connect() {}
    }
    for _ in 0..<100 where daemon.acceptedConnectionCount == 0 {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(daemon.acceptedConnectionCount == 1)

    oldReader.cancel()
    for _ in 0..<100 where !daemon.peerHasClosed(at: 0) {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(daemon.peerHasClosed(at: 0))
    await oldReader.value

    let newReader = Task {
      await firstEvent(of: client.connect())
    }
    for _ in 0..<100 where daemon.acceptedConnectionCount < 2 {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(daemon.acceptedConnectionCount == 2)
    try daemon.reply(.errorOccurred("after cancellation"), onConnection: 1)
    #expect(await newReader.value == .errorOccurred("after cancellation"))
    newReader.cancel()
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

  func peerHasClosed(at index: Int) -> Bool {
    guard
      let descriptor = lock.withLock({
        acceptedDescriptors.indices.contains(index) ? acceptedDescriptors[index] : nil
      }), descriptor >= 0
    else { return true }
    var byte: UInt8 = 0
    let result = recv(descriptor, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
    return result == 0
  }

  /// Reads one framed command off an accepted connection, waiting for the accept to land.
  /// Blocking reads run off the cooperative pool.
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

  /// Writes an event back the way `graphcoded` does — on the accepted connection.
  func reply(_ event: DaemonEvent, onConnection index: Int = 0) throws {
    guard let descriptor = waitForConnection(at: index) else { throw StubError.noConnection }
    try FramedMessageIO.writeFrame(try JSONEncoder().encode(event), to: descriptor)
  }

  /// Hangs up on one accepted connection, leaving the listener up — a daemon restart as
  /// the client experiences it. The slot is blanked rather than removed so later
  /// connections keep their indices, and so `stop` doesn't close the number twice.
  func closeConnection(at index: Int) {
    lock.withLock {
      guard acceptedDescriptors.indices.contains(index), acceptedDescriptors[index] >= 0
      else { return }
      close(acceptedDescriptors[index])
      acceptedDescriptors[index] = -1
    }
  }

  func stop() {
    lock.withLock {
      guard !stopped else { return }
      stopped = true
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
