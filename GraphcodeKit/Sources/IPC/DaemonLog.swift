import Foundation

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

/// `graphcoded`'s diagnostics — one line per IPC event, timestamped, `key=value`, and
/// never a payload (issue #289).
///
/// What it is for: when a `graphcode` command times out, saying *where* the ten seconds
/// went — reading, decoding, handling, persisting, encoding, or a write to one client that
/// stopped reading. Before this the daemon's log held bare `client connected` lines with
/// no clock, and the stall reproduced in the #288 report left no trace at all.
///
/// Three rules every line obeys:
///
/// - **Sizes and durations, never content.** A record names a command's *kind*, a frame's
///   byte count, a duration — never prompt text, mail bodies, tool output, paths inside
///   the repository, or a raw command. The API takes fields as `(key, value)` pairs, and
///   every caller in the daemon passes numbers, enum case names and descriptor numbers.
/// - **Off the IPC path.** `record` formats one string on the caller's thread and hands
///   it to a serial queue; the file write happens there. Logging never blocks an actor,
///   and never blocks the writer thread whose write it is measuring.
/// - **Bounded.** The file rolls over at `maxBytes` into one `.1` generation, so the
///   most the log ever occupies is two files of that size — plus whatever the mirrored
///   stdout and stderr wrote between two records, since rotation is decided at each
///   record from the file's real size. `graphcoded.log` had no bound before this — it
///   was 317 KB and growing on the machine that filed #289.
///
/// launchd hands the daemon `graphcoded.log` as its stdout. This opens the same file for
/// itself and, when stdout is not a terminal, moves stdout and stderr onto its own
/// descriptor — so anything still printed the old way, and the Swift runtime's own crash
/// output, lands in the file this rotates rather than in one that only ever grows.
public final class DaemonLog: @unchecked Sendable {
  public static let shared = DaemonLog()

  /// Two generations of this — `graphcoded.log` and `graphcoded.log.1` — is the
  /// documented bound.
  ///
  /// `record` costs its caller one string and one `DispatchQueue.async`: the file is
  /// written on the queue, under a lock only the queue takes. Neither the `GraphStore`
  /// actor nor a channel's writer thread can be held by the disk — the stall this log
  /// exists to measure must not be something the log can cause.
  public static let maxBytes = 2 * 1024 * 1024
  public static let fileName = "graphcoded.log"

  private let queue = DispatchQueue(label: "dev.graphcode.graphcoded.log", qos: .utility)
  /// Guards the file — descriptor, size, rotation — and is held across `write(2)`. Only
  /// the writer queue takes it. `record` never does: a caller must not wait on the disk,
  /// or measuring a stall could cause one.
  private let fileLock = NSLock()
  /// Guards the taps alone, so `record`'s only wait is for another `record`.
  private let tapLock = NSLock()
  private var descriptor: Int32 = -1
  private var url: URL?
  private var bytesWritten = 0
  private var limit = DaemonLog.maxBytes
  private var mirrorsStandardStreams = false
  private var taps: [UUID: @Sendable (String) -> Void] = [:]

  /// Something worth writing was said while the daemon was writing to a terminal, or
  /// before `open` ran — kept nowhere, since there is nothing to keep it in.
  public init() {}

  /// Opens `<directory>/graphcoded.log` for appending and, when stdout is not a terminal,
  /// routes stdout and stderr through it. `maxBytes` is exposed for tests; the daemon
  /// uses the default.
  /// `mirroringStandardStreams` routes this process's stdout and stderr through the file
  /// (skipped when stdout is a terminal). Only the daemon asks for it: a test that
  /// opened a log with it would move the test runner's own output onto a temp file.
  public func open(
    directory: URL, maxBytes: Int = DaemonLog.maxBytes, mirroringStandardStreams: Bool = false
  ) {
    fileLock.lock()
    defer { fileLock.unlock() }
    limit = maxBytes
    url = directory.appendingPathComponent(Self.fileName)
    mirrorsStandardStreams = mirroringStandardStreams && isatty(STDOUT_FILENO) == 0
    openLocked()
  }

  /// Sees every line as it is recorded — the test hook, and the way a future surface
  /// could stream diagnostics without reading the file.
  @discardableResult
  public func tap(_ handler: @escaping @Sendable (String) -> Void) -> UUID {
    let id = UUID()
    tapLock.lock()
    taps[id] = handler
    tapLock.unlock()
    return id
  }

  public func untap(_ id: UUID) {
    tapLock.lock()
    taps.removeValue(forKey: id)
    tapLock.unlock()
  }

  /// One line: `<utc stamp> event=<event> k=v k=v …`. Values are written as given —
  /// callers pass numbers and names, and a value with a space is quoted so the line
  /// still splits on whitespace.
  public func record(_ event: String, _ fields: [(String, String)] = []) {
    var line = Self.stamp() + " event=" + event
    for (key, value) in fields {
      line += " " + key + "=" + Self.quoted(value)
    }
    tapLock.lock()
    let observers = Array(taps.values)
    tapLock.unlock()
    for observer in observers { observer(line) }
    queue.async { [self] in write(line + "\n") }
  }

  /// A duration as the log spells it: milliseconds with one decimal, so a stall of
  /// seconds and a write of microseconds read on the same scale.
  public static func milliseconds(_ seconds: TimeInterval) -> String {
    String(format: "%.1f", seconds * 1000)
  }

  /// Flushes what has been recorded so far — for tests reading the file back.
  public func drain() {
    queue.sync {}
  }

  // MARK: - The file

  private func write(_ text: String) {
    fileLock.lock()
    defer { fileLock.unlock() }
    guard descriptor >= 0 else { return }
    let data = Data(text.utf8)
    // The file's real size, not a running count of this log's own lines: stdout and
    // stderr write to the same file through the mirrored descriptors, and those bytes
    // count against the bound too — a bound that only saw its own records was
    // measured 25× over.
    var info = stat()
    let size = fstat(descriptor, &info) == 0 ? Int(info.st_size) : bytesWritten
    if size + data.count > limit { rotateLocked() }
    data.withUnsafeBytes { raw in
      var remaining = raw.count
      var pointer = raw.baseAddress!
      while remaining > 0 {
        #if canImport(Darwin)
          let written = Darwin.write(descriptor, pointer, remaining)
        #else
          let written = Glibc.write(descriptor, pointer, remaining)
        #endif
        guard written > 0 else { return }
        remaining -= written
        pointer = pointer.advanced(by: written)
      }
    }
    bytesWritten += data.count
  }

  private func openLocked() {
    guard let url else { return }
    let opened = url.path.withCString { path in
      #if canImport(Darwin)
        Darwin.open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
      #else
        Glibc.open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
      #endif
    }
    guard opened >= 0 else { return }
    descriptor = opened
    var info = stat()
    bytesWritten = fstat(opened, &info) == 0 ? Int(info.st_size) : 0
    if mirrorsStandardStreams {
      dup2(opened, STDOUT_FILENO)
      dup2(opened, STDERR_FILENO)
    }
  }

  /// `graphcoded.log` becomes `graphcoded.log.1`, replacing the previous generation, and
  /// a fresh file takes its place. Stdout and stderr follow, so nothing keeps writing
  /// into the rotated file.
  private func rotateLocked() {
    guard let url else { return }
    #if canImport(Darwin)
      _ = Darwin.close(descriptor)
    #else
      _ = Glibc.close(descriptor)
    #endif
    descriptor = -1
    let previous = url.path + ".1"
    _ = url.path.withCString { current in previous.withCString { rename(current, $0) } }
    openLocked()
  }

  // MARK: - Formatting

  private static let stampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter
  }()

  private static let stampLock = NSLock()

  private static func stamp() -> String {
    stampLock.lock()
    defer { stampLock.unlock() }
    return stampFormatter.string(from: Date())
  }

  private static func quoted(_ value: String) -> String {
    guard value.contains(" ") || value.contains("\"") else { return value }
    return "\"" + value.replacingOccurrences(of: "\"", with: "'") + "\""
  }
}

extension DaemonCommand {
  /// The command's shape for a log line — the case name, and for a `graphCommand` the
  /// inner case too — never its payload.
  public var kindName: String {
    switch self {
    case .graphCommand(_, let command): return "graphCommand." + command.kindName
    default: return Self.caseName(of: self)
    }
  }

  static func caseName(of value: Any) -> String {
    let mirror = Mirror(reflecting: value)
    if let label = mirror.children.first?.label { return label }
    return String(describing: value)
  }
}

extension GraphCommand {
  public var kindName: String {
    if case .subGraphCommand(_, let inner) = self { return "subGraphCommand." + inner.kindName }
    return DaemonCommand.caseName(of: self)
  }
}

extension DaemonEvent {
  public var kindName: String { DaemonCommand.caseName(of: self) }
}

/// The request being handled, for lines recorded deeper in the daemon — the store's
/// persist and broadcast, the registry's reply — to carry the same `conn`/`seq` as the
/// connection loop's own line, so one command's phases read as one story.
public enum DaemonRequestContext {
  public struct Request: Sendable {
    public let connection: Int
    public let sequence: Int
    public init(connection: Int, sequence: Int) {
      self.connection = connection
      self.sequence = sequence
    }
  }

  @TaskLocal public static var current: Request?

  /// The fields every line inside a request starts with, or none outside one (the
  /// presence poll, a timer).
  public static var fields: [(String, String)] {
    guard let current else { return [] }
    return [("conn", String(current.connection)), ("seq", String(current.sequence))]
  }
}

/// Who is on the other end of a unix socket — the peer's pid, and nothing else.
///
/// Why a diagnostics path reads peer credentials at all, since it is the one field
/// here that crosses a process boundary: #289 asks that a CLI timeout name an id usable
/// across the CLI's and the daemon's records, and there is no wire change in this
/// series. The pid is the one identifier both sides already know — the CLI prints its
/// own on timeout, the daemon logs the peer's on connect — so the two records can be
/// joined from outside. An id the daemon minted would tell two connections apart in the
/// log but could never be printed by a client that never learns it, which leaves that
/// criterion unsatisfiable without a protocol change. A pid identifies a process, not a
/// person, is visible to anyone on the machine with `ps`, and is used as a credential
/// nowhere. The uid and gid that `SO_PEERCRED` also returns are discarded unread.
public enum SocketPeer {
  #if !canImport(Darwin)
    /// Linux's `struct ucred`, spelled out: Glibc's Swift module does not export the
    /// type, only the `SO_PEERCRED` option that fills it.
    private struct PeerCredentials {
      var pid: pid_t = 0
      var uid: uid_t = 0
      var gid: gid_t = 0
    }
  #endif

  public static func pid(of fileDescriptor: Int32) -> Int32? {
    #if canImport(Darwin)
      var pid: pid_t = 0
      var size = socklen_t(MemoryLayout<pid_t>.size)
      guard getsockopt(fileDescriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0 else {
        return nil
      }
      return pid
    #else
      var credentials = PeerCredentials()
      var size = socklen_t(MemoryLayout<PeerCredentials>.size)
      guard getsockopt(fileDescriptor, SOL_SOCKET, SO_PEERCRED, &credentials, &size) == 0
      else { return nil }
      return credentials.pid
    #endif
  }
}

extension UUID {
  /// The first eight characters — enough to tell connections apart in a log, short
  /// enough to read; the daemon's `connect` line carries it as `id=`.
  public var tag: String { String(uuidString.prefix(8)) }
}
