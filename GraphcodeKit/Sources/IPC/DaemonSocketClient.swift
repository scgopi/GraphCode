import Foundation

#if canImport(Darwin)
  import Darwin
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

  private let fileDescriptor: Int32

  /// How long a single read waits before giving up. Generous on purpose: it exists to
  /// turn "hangs forever with no output" into a diagnosable error, not to bound how long
  /// a legitimately slow daemon may take. Anything the daemon actually intends to answer
  /// arrives in milliseconds over a local socket.
  public static let defaultTimeout: TimeInterval = 10

  public init(timeout: TimeInterval = DaemonSocketClient.defaultTimeout) throws {
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
        _ = path.withCString { strncpy(pointer, $0, MemoryLayout.size(ofValue: field.pointee) - 1) }
      }
    }

    let connected = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard connected == 0 else {
      close(descriptor)
      throw ClientError.connectionFailed(errno: errno)
    }

    // `SO_RCVTIMEO` rather than a watchdog thread: it makes the blocking `read(2)` inside
    // `FramedMessageIO` return `EAGAIN` on its own, which keeps this type synchronous and
    // needs no cancellation plumbing. Without it a caller waiting on an event the daemon
    // never sends — because nothing it sent would cause one — blocks forever with no
    // output at all, which is exactly how `status` used to hang.
    var interval = timeval(
      tv_sec: Int(timeout),
      tv_usec: Int32((timeout - timeout.rounded(.down)) * 1_000_000))
    setsockopt(
      descriptor, SOL_SOCKET, SO_RCVTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))

    fileDescriptor = descriptor
  }

  /// Wraps an already-connected descriptor. Exists so the timeout and framing behaviour
  /// can be exercised over a `socketpair` — the public `init` dials the daemon's fixed
  /// socket path, which a test can't stand in for without disturbing the real daemon.
  init(fileDescriptor: Int32, timeout: TimeInterval = DaemonSocketClient.defaultTimeout) {
    var interval = timeval(
      tv_sec: Int(timeout),
      tv_usec: Int32((timeout - timeout.rounded(.down)) * 1_000_000))
    setsockopt(
      fileDescriptor, SOL_SOCKET, SO_RCVTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))
    self.fileDescriptor = fileDescriptor
  }

  public func send(_ command: DaemonCommand) throws {
    try FramedMessageIO.writeFrame(JSONEncoder().encode(command), to: fileDescriptor)
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
    for _ in 0..<limit {
      let data: Data
      do {
        data = try FramedMessageIO.readFrame(from: fileDescriptor)
      } catch FramedMessageIO.IOError.readFailed(let code)
        where code == EAGAIN || code == EWOULDBLOCK
      {
        throw ClientError.timedOut
      }
      guard let event = try? JSONDecoder().decode(DaemonEvent.self, from: data) else { continue }
      if isSatisfied(event) { return event }
    }
    return nil
  }

  public func closeConnection() {
    close(fileDescriptor)
  }
}
