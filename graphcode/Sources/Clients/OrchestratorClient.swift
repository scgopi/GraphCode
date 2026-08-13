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

private final class ReaderToken: @unchecked Sendable {
  private let lock = NSLock()
  private var readerID: UInt64?

  func set(_ readerID: UInt64) {
    lock.lock()
    self.readerID = readerID
    lock.unlock()
  }

  var value: UInt64? {
    lock.lock()
    defer { lock.unlock() }
    return readerID
  }
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
    let connection = AppDaemonConnection(socketPath: socketPath)
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
private actor AppDaemonConnection {
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
  private var connection: Task<any DaemonConnection, any Error>?

  /// Bumped whenever `connection` is dropped, so a late failure handler can tell whether
  /// the attempt it was holding is still the current one.
  private var generation = 0
  private var nextReaderID: UInt64 = 0
  private var activeReaderID: UInt64?
  /// A replacement socket must be joined exactly once, regardless of whether the reader
  /// or a concurrent send is first to observe it.
  private var rejoinConnectionID: UUID?
  private var restoreTask: Task<Void, any Error>?
  private var globalJoinTask: Task<Void, any Error>?

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
      let token = ReaderToken()
      let task = Task {
        let readerID = await beginReader()
        token.set(readerID)
        defer {
          continuation.finish()
          Task { await endReader(readerID) }
        }
        while !Task.isCancelled {
          var connectedConnection: (any DaemonConnection)?
          do {
            guard await isCurrentReader(readerID) else { return }
            let connection = try await ensureConnected()
            guard await isCurrentReader(readerID) else {
              try? await connection.close()
              return
            }
            connectedConnection = connection
            if await isReconnect() { try await rejoinProjects(on: connection) }
            while !Task.isCancelled {
              guard await isCurrentReader(readerID) else { return }
              let data = try await connection.receiveFrame()
              let event = try JSONDecoder().decode(DaemonEvent.self, from: data)
              continuation.yield(event)
            }
          } catch {
            if let connectedConnection {
              await readerFailed(readerID, connection: connectedConnection)
            }
            guard !Task.isCancelled, await isCurrentReader(readerID) else { return }
            do {
              try await Task.sleep(for: .seconds(1))
            } catch {
              return
            }
          }
        }
      }
      continuation.onTermination = { _ in
        task.cancel()
        Task {
          while token.value == nil { await Task.yield() }
          if let readerID = token.value {
            await endReader(readerID)
          }
        }
      }
    }
  }

  /// Whether a connection has been established before this one — `AppFeature.task` sends
  /// the join commands for the first, and `rejoinProjects` covers every one after it.
  private var hasConnectedBefore = false

  private func isReconnect() -> Bool {
    defer { hasConnectedBefore = true }
    return hasConnectedBefore
  }

  private func beginReader() async -> UInt64 {
    let readerID = nextReaderID
    nextReaderID = nextReaderID == UInt64.max ? 0 : nextReaderID + 1
    let hadReader = activeReaderID != nil
    activeReaderID = readerID
    guard hadReader else { return readerID }

    let oldConnection = connection
    connection = nil
    generation += 1
    clearRejoinState()
    if let oldConnection {
      oldConnection.cancel()
      if let resolved = try? await oldConnection.value {
        try? await resolved.close()
      }
    }
    return readerID
  }

  private func isCurrentReader(_ readerID: UInt64) -> Bool {
    activeReaderID == readerID
  }

  private func endReader(_ readerID: UInt64) async {
    guard activeReaderID == readerID else { return }
    activeReaderID = nil
    let currentConnection = connection
    connection = nil
    generation += 1
    clearRejoinState()
    if let currentConnection {
      currentConnection.cancel()
      if let resolved = try? await currentConnection.value {
        try? await resolved.close()
      }
    }
  }

  private func readerFailed(_ readerID: UInt64, connection: any DaemonConnection) async {
    guard activeReaderID == readerID else {
      try? await connection.close()
      return
    }
    await invalidate(connection)
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
  private func rejoinProjects(on connection: any DaemonConnection) async throws {
    try await ensureRejoined(connection)
  }

  func send(_ command: DaemonCommand) async throws {
    let connection = try await ensureConnected()
    do {
      switch command {
      case .restoreOpenProjects, .openGlobalGraph:
        // These are the public join commands used by app startup. Coalesce each with
        // reconnect rejoin so concurrent startup sends cannot duplicate a join.
        try await sendJoin(command, on: connection)
      case .listRecentProjects:
        try await sendRaw(command, on: connection)
      case .openProject, .closeProject, .forgetProject, .deleteProjectGraph, .graphCommand:
        try await ensureRejoined(connection)
        try await sendRaw(command, on: connection)
      }
    } catch {
      await invalidate(connection)
      throw error
    }
  }

  private func ensureConnected() async throws -> any DaemonConnection {
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

  /// Coalesces the two commands that establish this client's project/global membership.
  ///
  /// The task is keyed by the transport identity rather than the actor's generation so a
  /// send-created replacement socket and the reader's reconnect path share the same work.
  private func ensureRejoined(_ connection: any DaemonConnection) async throws {
    try await sendJoin(.restoreOpenProjects, on: connection)
    try await sendJoin(.openGlobalGraph, on: connection)
  }

  private func sendJoin(
    _ command: DaemonCommand,
    on connection: any DaemonConnection
  ) async throws {
    if rejoinConnectionID != connection.id {
      clearRejoinState()
      rejoinConnectionID = connection.id
    }
    let existingTask: Task<Void, any Error>?
    switch command {
    case .restoreOpenProjects:
      existingTask = restoreTask
    case .openGlobalGraph:
      existingTask = globalJoinTask
    default:
      preconditionFailure("only join commands can use sendJoin")
    }
    if let existingTask {
      do {
        try await existingTask.value
        return
      } catch {
        if rejoinConnectionID == connection.id {
          clearJoinTask(command)
        }
        throw error
      }
    }

    let task = Task { () throws -> Void in
      try await sendRaw(command, on: connection)
    }
    switch command {
    case .restoreOpenProjects:
      restoreTask = task
    case .openGlobalGraph:
      globalJoinTask = task
    default:
      preconditionFailure("only join commands can use sendJoin")
    }
    do {
      try await task.value
    } catch {
      if rejoinConnectionID == connection.id {
        clearJoinTask(command)
      }
      throw error
    }
  }

  private func clearJoinTask(_ command: DaemonCommand) {
    switch command {
    case .restoreOpenProjects:
      restoreTask = nil
    case .openGlobalGraph:
      globalJoinTask = nil
    default:
      break
    }
  }

  private func sendRaw(_ command: DaemonCommand, on connection: any DaemonConnection) async throws {
    try await connection.sendFrame(try JSONEncoder().encode(command))
  }

  private func clearRejoinState() {
    restoreTask?.cancel()
    globalJoinTask?.cancel()
    restoreTask = nil
    globalJoinTask = nil
    rejoinConnectionID = nil
  }

  /// Drops the shared connection after an I/O failure, so the next `send` or `events()`
  /// dials again instead of writing into a socket the daemon has gone from.
  ///
  /// Closes the failed transport as well as dropping it: `events()` can be parked in a
  /// blocking `read` on another thread, and closing under that read is what wakes the old
  /// reader so it cannot race a replacement connection.
  private func invalidate(_ failedConnection: any DaemonConnection) async {
    guard let connection, let currentConnection = try? await connection.value,
      currentConnection.id == failedConnection.id
    else { return }
    self.connection = nil
    generation += 1
    clearRejoinState()
    connection.cancel()
    try? await failedConnection.close()
  }

  private func connectWithBackoff() async throws -> any DaemonConnection {
    var lastError: any Error = OrchestratorClientError.connectFailed(errno: 0)
    for attempt in 0..<10 {
      try Task.checkCancellation()
      do {
        return try await connectAsync()
      } catch {
        lastError = error
        do {
          try await Task.sleep(for: .milliseconds(200 * (attempt + 1)))
        } catch {
          throw CancellationError()
        }
      }
    }

    throw lastError
  }

  @Sendable
  private func connectAsync() async throws -> any DaemonConnection {
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
        continuation.resume(
          returning: UnixSocketConnection(
            fileDescriptor: fd,
            endpoint: .unixSocket(URL(fileURLWithPath: path)),
            writeTimeout: 5))
      }
    }
  }
}
