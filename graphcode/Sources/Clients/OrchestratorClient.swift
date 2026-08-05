import Dependencies
import Foundation
import GraphcodeKit

#if canImport(Darwin)
  import Darwin
#endif

/// The app's thin proxy to `graphcoded`'s `GraphStore` — see
/// docs/03-architecture.md#clients. `GraphCanvasFeature` no longer owns graph state
/// itself; it mirrors whatever `graphcoded` broadcasts and sends commands for every
/// mutation, so automatic edge firing and time-based triggers (which the daemon can
/// run with no app attached at all) and the app's own view of the graph never
/// disagree.
struct OrchestratorClient: Sendable {
  var connect: @Sendable () -> AsyncStream<DaemonEvent>
  var send: @Sendable (_ command: DaemonCommand) async throws -> Void
}

enum OrchestratorClientError: Error, Equatable {
  case connectFailed(errno: Int32)
}

extension OrchestratorClient: DependencyKey {
  static let liveValue: OrchestratorClient = live(socketPath: DaemonSocketPath.url)

  /// One `DaemonConnection` per client — `connect` and `send` deliberately share it, see
  /// `DaemonConnection.connection`. Parameterized on the socket path so tests can point
  /// a client at a socket they own instead of the real daemon's.
  static func live(socketPath: URL) -> OrchestratorClient {
    let connection = DaemonConnection(socketPath: socketPath)
    return OrchestratorClient(
      connect: { connection.events() },
      send: { command in try await connection.send(command) }
    )
  }
}

extension DependencyValues {
  var orchestratorClient: OrchestratorClient {
    get { self[OrchestratorClient.self] }
    set { self[OrchestratorClient.self] = newValue }
  }
}

/// Owns the one socket connection to `graphcoded`, connecting lazily and retrying with
/// backoff — the app can launch before the daemon has finished starting up.
private actor DaemonConnection {
  private let socketPath: URL

  /// The one connect attempt, in flight or finished — **not** a bare file descriptor.
  ///
  /// `graphcoded` answers on the connection a command arrived on (`ProjectRegistry.handle`
  /// replies to that connection's descriptor, and `GraphStore.addConnection` sends its
  /// `graphChanged` snapshot the same way), so the socket `send` writes to has to be the
  /// socket `events()` is reading. Caching a descriptor instead let that invariant break:
  /// `AppFeature.task` starts `connect()` and `send(.listRecentProjects)` in the same
  /// `.merge`, both reached the `if let fileDescriptor` check before the first connect had
  /// resumed, and each opened its own socket — after which every reply the daemon wrote
  /// landed on the descriptor nobody read, and the UI never saw an event. Storing the
  /// `Task` means the second caller awaits the first caller's attempt: one socket, one
  /// reader, replies land where they're expected.
  private var connection: Task<Int32, any Error>?

  /// Bumped whenever `connection` is dropped, so a late failure handler can tell whether
  /// the attempt it was holding is still the current one.
  private var generation = 0

  init(socketPath: URL) {
    self.socketPath = socketPath
  }

  /// Reconnects forever rather than finishing the stream on the first failure — the app
  /// can launch before `graphcoded` has finished starting up, and `ensureConnected`'s own
  /// backoff (10 attempts, ~11s total) can still lose that race. Finishing here would
  /// leave `send` able to silently open a fresh connection later (writing commands the
  /// daemon happily answers) with nothing left subscribed to read the replies — the app
  /// would look connected but never update again.
  nonisolated func events() -> AsyncStream<DaemonEvent> {
    AsyncStream { continuation in
      let task = Task {
        while !Task.isCancelled {
          var connectedDescriptor: Int32?
          do {
            let fileDescriptor = try await ensureConnected()
            connectedDescriptor = fileDescriptor
            if await isReconnect() { try await rejoinProjects() }
            while true {
              let data = try await readFrameAsync(from: fileDescriptor)
              let event = try JSONDecoder().decode(DaemonEvent.self, from: data)
              continuation.yield(event)
            }
          } catch {
            if let connectedDescriptor { await invalidate(connectedDescriptor) }
            try? await Task.sleep(for: .seconds(1))
          }
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  /// Whether a connection has been established before this one — `AppFeature.task` sends
  /// the join commands for the first, and `rejoinProjects` covers every one after it.
  private var hasConnectedBefore = false

  private func isReconnect() -> Bool {
    defer { hasConnectedBefore = true }
    return hasConnectedBefore
  }

  /// Re-announces which projects this client wants, on a socket that replaced one that
  /// failed.
  ///
  /// `graphcoded` keys a client's joined projects by *connection*
  /// (`ProjectRegistry.connectionProjectPaths`), and the app asked to join from
  /// `AppFeature.task` — once, at launch. So a reconnect left the new socket attached to
  /// no `GraphStore` at all: commands still arrived and still took effect, but every
  /// broadcast went to the connection that had gone. The app looked connected and stayed
  /// frozen on whatever it last knew, which is how deleting a loop could remove it from
  /// the daemon's graph while its row sat in the sidebar until the next relaunch.
  ///
  /// The same two commands the launch path sends: the daemon's own open-projects set is
  /// the right one to restore from, and the global graph is joined by name because it is
  /// deliberately not in that set.
  private func rejoinProjects() async throws {
    try await send(.restoreOpenProjects)
    try await send(.openGlobalGraph)
  }

  func send(_ command: DaemonCommand) async throws {
    let fileDescriptor = try await ensureConnected()
    let data = try JSONEncoder().encode(command)
    do {
      try await writeFrameAsync(data, to: fileDescriptor)
    } catch {
      await invalidate(fileDescriptor)
      throw error
    }
  }

  private func ensureConnected() async throws -> Int32 {
    if let connection { return try await connection.value }
    let attemptGeneration = generation
    let attempt = Task { try await connectWithBackoff() }
    connection = attempt
    do {
      return try await attempt.value
    } catch {
      // Don't cache a failed attempt — the next caller should get a fresh one. Guard on
      // the generation so a concurrent `invalidate` that already replaced it wins.
      if generation == attemptGeneration {
        connection = nil
        generation += 1
      }
      throw error
    }
  }

  /// Drops the shared connection after an I/O failure, so the next `send` or `events()`
  /// dials again instead of writing into a socket the daemon has gone from.
  ///
  /// Deliberately does not `close` the descriptor: `events()` can be parked in a blocking
  /// `read` on it from another thread, and closing under that read frees the number for
  /// any other socket the process opens next. Costs one stranded descriptor per daemon
  /// restart, which the process reclaims on exit.
  private func invalidate(_ fileDescriptor: Int32) async {
    guard let connection, let currentDescriptor = try? await connection.value,
      currentDescriptor == fileDescriptor
    else { return }
    self.connection = nil
    generation += 1
  }

  private func connectWithBackoff() async throws -> Int32 {
    var lastError: any Error = OrchestratorClientError.connectFailed(errno: 0)
    for attempt in 0..<10 {
      do {
        return try await connectAsync()
      } catch {
        lastError = error
        try? await Task.sleep(for: .milliseconds(200 * (attempt + 1)))
      }
    }
    throw lastError
  }

  @Sendable
  private func connectAsync() async throws -> Int32 {
    let path = socketPath.path
    return try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global().async {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
          continuation.resume(throwing: OrchestratorClientError.connectFailed(errno: errno))
          return
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutablePointer(to: &address.sun_path) { pathField in
          pathField.withMemoryRebound(
            to: CChar.self, capacity: MemoryLayout.size(ofValue: pathField.pointee)
          ) { pathPointer in
            _ = path.withCString { cPath in
              strncpy(pathPointer, cPath, MemoryLayout.size(ofValue: pathField.pointee) - 1)
            }
          }
        }

        let connectResult = withUnsafePointer(to: &address) { addressPointer -> Int32 in
          addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rawPointer in
            connect(fd, rawPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
          }
        }
        guard connectResult == 0 else {
          let capturedErrno = errno
          close(fd)
          continuation.resume(throwing: OrchestratorClientError.connectFailed(errno: capturedErrno))
          return
        }
        continuation.resume(returning: fd)
      }
    }
  }
}

@Sendable
private func readFrameAsync(from fileDescriptor: Int32) async throws -> Data {
  try await withCheckedThrowingContinuation { continuation in
    DispatchQueue.global().async {
      do {
        continuation.resume(returning: try FramedMessageIO.readFrame(from: fileDescriptor))
      } catch {
        continuation.resume(throwing: error)
      }
    }
  }
}

@Sendable
private func writeFrameAsync(_ data: Data, to fileDescriptor: Int32) async throws {
  try await withCheckedThrowingContinuation { continuation in
    DispatchQueue.global().async {
      do {
        try FramedMessageIO.writeFrame(data, to: fileDescriptor)
        continuation.resume()
      } catch {
        continuation.resume(throwing: error)
      }
    }
  }
}
