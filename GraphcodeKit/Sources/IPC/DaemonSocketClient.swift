import Foundation

#if canImport(Darwin)
  import Darwin
#endif
#if os(Windows)
  import WinSDK
#endif

/// A short-lived client for `graphcoded`'s socket — what the `graphcode` CLI talks
/// through (docs/03-architecture.md#cli-graphcode).
///
/// The CLI targets the *daemon*, not the app, deliberately: `graphcode node create …`
/// has to work identically whether or not a window happens to be open, and that only
/// holds if the socket target is the thing that outlives the app. The app is just
/// another client of this same protocol.
///
/// Blocking and synchronous, unlike the app's `OrchestratorClient`: a CLI process
/// connects, says one thing, waits for the reply, and exits. There's no subscription to
/// maintain and nothing else for the process to be doing meanwhile.
public struct DaemonSocketClient: Sendable {
  public enum ClientError: Error, Equatable {
    case daemonNotRunning
    case connectionFailed(errno: Int32)
    case timedOut
  }

  public static let ambiguousExitCode: Int32 = 75

  public static func isAmbiguousConnectionClose(_ error: Error) -> Bool {
    if case FramedMessageIO.IOError.connectionClosed = error {
      return true
    }
    #if os(Windows)
      if case WindowsPipeError.connectionClosed = error {
        return true
      }
    #endif
    return false
  }

  private let connection: any DaemonConnection
  private let timeout: TimeInterval

  /// How long a single read waits before giving up. Generous on purpose: it exists to
  /// turn "hangs forever with no output" into a diagnosable error, not to bound how long
  /// a legitimately slow daemon may take. Anything the daemon actually intends to answer
  /// arrives in milliseconds over a local socket.
  public static let defaultTimeout: TimeInterval = 10

  /// How many times `init` dials before giving up.
  ///
  /// graphcoded is restarted by launchd and by its own upgrades, so a burst of CLI calls
  /// that straddles a restart gets `ECONNREFUSED` — or a socket path that has momentarily
  /// vanished — from a daemon that is about to be perfectly healthy. Redialing is safe in
  /// a way retrying a *command* is not: nothing has been written yet, so there is no
  /// half-applied mutation to duplicate. Anything past the first `send` is deliberately
  /// left to the caller.
  public static let defaultDialAttempts = 4

  private static let dialBackoff: [TimeInterval] = [0.05, 0.15, 0.35]

  public init(
    timeout: TimeInterval = DaemonSocketClient.defaultTimeout,
    dialAttempts: Int = DaemonSocketClient.defaultDialAttempts
  ) throws {
    let requestedTimeout = max(0, timeout)
    self.timeout = requestedTimeout
    let budget = max(1, dialAttempts)
    #if os(Windows)
      let dialDeadline = Date().addingTimeInterval(requestedTimeout)
    #endif
    #if canImport(Darwin)
      var descriptor: Int32?
    #endif
    for attempt in 0..<budget {
      do {
        #if os(Windows)
          let remaining = max(0, dialDeadline.timeIntervalSinceNow)
          let pipe = try Self.dial(timeout: remaining)
          connection = pipe
          return
        #else
          descriptor = try Self.dial()
          break
        #endif
      } catch {
        guard Self.isTransient(error), attempt < budget - 1 else { throw error }
        #if os(Windows)
          let remaining = dialDeadline.timeIntervalSinceNow
          guard remaining > 0 else { throw error }
          Thread.sleep(
            forTimeInterval: min(
              remaining, Self.dialBackoff[min(attempt, Self.dialBackoff.count - 1)]))
        #else
          Thread.sleep(
            forTimeInterval: Self.dialBackoff[min(attempt, Self.dialBackoff.count - 1)])
        #endif
      }
    }
    #if os(Windows)
      throw ClientError.daemonNotRunning
    #else
      guard let connected = descriptor else { throw ClientError.daemonNotRunning }
      connection = UnixSocketConnection(fileDescriptor: connected, readTimeout: timeout)
    #endif
  }

  /// Wraps an already-connected descriptor. Exists so the timeout and framing behaviour
  /// can be exercised over a `socketpair` — the public `init` dials the daemon's fixed
  /// socket path, which a test can't stand in for without disturbing the real daemon.
  #if canImport(Darwin)
    init(fileDescriptor: Int32, timeout: TimeInterval = DaemonSocketClient.defaultTimeout) {
      self.timeout = max(0, timeout)
      connection = UnixSocketConnection(fileDescriptor: fileDescriptor, readTimeout: timeout)
    }
  #endif

  /// Only failures that mean "not accepting connections *yet*". A permissions failure or a
  /// bad path fails identically however long you wait, and retrying those just delays the
  /// error the caller needs to see.
  static func isTransient(_ error: Error) -> Bool {
    switch error {
    case ClientError.daemonNotRunning:
      return true
    case ClientError.connectionFailed(let code):
      #if os(Windows)
        return code == Int32(truncatingIfNeeded: ERROR_FILE_NOT_FOUND)
          || code == Int32(truncatingIfNeeded: ERROR_PIPE_BUSY)
          || code == Int32(truncatingIfNeeded: ERROR_SEM_TIMEOUT)
          || code == Int32(truncatingIfNeeded: ERROR_PIPE_NOT_CONNECTED)
      #else
        return code == ECONNREFUSED || code == ENOENT || code == EAGAIN || code == EINTR
      #endif
    default:
      return false
    }
  }

  #if os(Windows)
    private static func dial(timeout: TimeInterval) throws -> WindowsNamedPipeConnection {
      do {
        return try WindowsNamedPipeClient.connect(
          to: try WindowsNamedPipeEndpoint.name(),
          timeoutMilliseconds: timeoutMilliseconds(timeout))
      } catch WindowsPipeError.win32(_, let code) {
        throw ClientError.connectionFailed(errno: Int32(bitPattern: code))
      } catch WindowsPipeError.timedOut {
        throw ClientError.connectionFailed(
          errno: Int32(truncatingIfNeeded: ERROR_SEM_TIMEOUT))
      } catch WindowsPipeError.serverIdentityRejected {
        throw ClientError.connectionFailed(
          errno: Int32(truncatingIfNeeded: ERROR_ACCESS_DENIED))
      }
    }

    private static func timeoutMilliseconds(_ timeout: TimeInterval) -> UInt32 {
      guard timeout.isFinite else { return UInt32.max }
      return UInt32(
        min(Double(UInt32.max), max(0, (timeout * 1_000).rounded(.up))))
    }
  #else
    private static func dial() throws -> Int32 {
      let path = DaemonSocketPath.url.path
      guard FileManager.default.fileExists(atPath: path) else {
        throw ClientError.daemonNotRunning
      }

      let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
      guard descriptor >= 0 else { throw ClientError.connectionFailed(errno: errno) }

      var address = sockaddr_un()
      address.sun_family = sa_family_t(AF_UNIX)
      address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
      withUnsafeMutablePointer(to: &address.sun_path) { field in
        field.withMemoryRebound(
          to: CChar.self, capacity: MemoryLayout.size(ofValue: field.pointee)
        ) { pointer in
          _ = path.withCString {
            strncpy(pointer, $0, MemoryLayout.size(ofValue: field.pointee) - 1)
          }
        }
      }

      let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
      }
      guard connected == 0 else {
        // Captured before `close`, which is itself a syscall and may overwrite `errno` —
        // reading it afterwards reported whatever closing did, not why dialling failed.
        let code = errno
        close(descriptor)
        throw ClientError.connectionFailed(errno: code)
      }
      return descriptor
    }
  #endif

  /// `SO_RCVTIMEO` rather than a watchdog thread: it makes the blocking `read(2)` inside
  /// `FramedMessageIO` return `EAGAIN` on its own, which keeps this type synchronous and
  /// needs no cancellation plumbing. Without it a caller waiting on an event the daemon
  /// never sends — because nothing it sent would cause one — blocks forever with no
  /// output at all, which is exactly how `status` used to hang.
  public func send(_ command: DaemonCommand) throws {
    let data = try JSONEncoder().encode(command)
    #if canImport(Darwin)
      try (connection as! UnixSocketConnection).sendFrameSync(data)
    #else
      try Self.blocking { try await connection.sendFrame(data) }
    #endif
  }

  /// Reads events until `isSatisfied` accepts one, the connection closes, or the read
  /// times out (`ClientError.timedOut`).
  ///
  /// The daemon has no request/response correlation — it broadcasts `.graphChanged` for
  /// whatever changed — so a caller says what it's waiting for rather than assuming the
  /// next frame is its answer. The flip side of that design is that waiting for something
  /// the daemon was never going to send is indistinguishable from waiting for something
  /// slow, which is why this fails loudly instead of blocking: `limit` bounds how many
  /// frames may arrive without satisfying the caller, and the socket's receive timeout
  /// bounds how long a single read may produce nothing at all.
  public func waitForEvent(
    matching isSatisfied: (DaemonEvent) -> Bool,
    limit: Int = 64
  ) throws -> DaemonEvent? {
    #if os(Windows)
      let responseDeadline = Date().addingTimeInterval(timeout)
    #endif
    for _ in 0..<limit {
      let data: Data
      do {
        #if canImport(Darwin)
          data = try (connection as! UnixSocketConnection).receiveFrameSync()
        #else
          data = try Self.blocking {
            if let pipe = connection as? WindowsNamedPipeConnection {
              return try await pipe.receiveFrameWithDeadline(
                max(0, responseDeadline.timeIntervalSinceNow))
            }
            return try await connection.receiveFrame()
          }
        #endif
      } catch {
        #if canImport(Darwin)
          if case FramedMessageIO.IOError.readFailed(let code) = error,
            code == EAGAIN || code == EWOULDBLOCK
          {
            throw ClientError.timedOut
          }
        #endif
        #if os(Windows)
          if case WindowsPipeError.timedOut = error {
            throw ClientError.timedOut
          }
        #endif
        throw error
      }
      guard let event = try? JSONDecoder().decode(DaemonEvent.self, from: data) else { continue }
      if isSatisfied(event) { return event }
    }
    return nil
  }

  public func closeConnection() {
    #if canImport(Darwin)
      (connection as? UnixSocketConnection)?.closeSync()
    #else
      try? Self.blocking { try await connection.close() }
    #endif
  }

  #if os(Windows)
    private static func blocking<Result>(
      _ operation: @escaping () async throws -> Result
    ) throws -> Result {
      let semaphore = DispatchSemaphore(value: 0)
      let box = BlockingResult<Result>()
      Task {
        do {
          box.store(.success(try await operation()))
        } catch {
          box.store(.failure(error))
        }
        semaphore.signal()
      }
      semaphore.wait()
      return try box.take()
    }

    private final class BlockingResult<Value>: @unchecked Sendable {
      private let lock = NSLock()
      private var value: Result<Value, Error>?

      func store(_ value: Result<Value, Error>) {
        lock.lock()
        self.value = value
        lock.unlock()
      }

      func take() throws -> Value {
        lock.lock()
        defer { lock.unlock() }
        guard let value else { fatalError("blocking result was not set") }
        return try value.get()
      }
    }
  #endif
}
