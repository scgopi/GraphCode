import Foundation
import GraphcodeKit

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

// graphcoded — the graphcode orchestrator daemon.
//
// From Phase 3 on this is no longer an empty skeleton (see docs/07-roadmap.md): it
// speaks `DaemonProtocol` over the Unix socket, fires `.handoff` edges automatically,
// and arms time-based triggers that keep firing whether or not `graphcode.app` is
// running — see docs/03-architecture.md#why-a-daemon-at-all for why this has to be a
// separate, long-lived process rather than in-app state. From Phase 4 on it hosts one
// `LoopGraph` per opened project (`ProjectRegistry`, wrapping one `GraphStore` per
// project) rather than a single hardcoded graph, each persisted under this directory.

let fileManager = FileManager.default

// Launched by an agent rather than launchd — `make daemon-install` from a loop's own
// shell — the daemon inherits that session's identity and would hand it to every backend
// it starts. See `AgentEnvironment`.
AgentEnvironment.scrubInheritedAgentIdentity()

// Migrates a pre-existing `~/Library/Application Support/graphcode` and creates the
// directory. Has to happen before anything reads or writes — including the socket bind
// immediately below.
SupportDirectory.prepare()
let supportDirectory = SupportDirectory.url

let socketURL = DaemonSocketPath.url
// Clear a stale socket file left behind by a previous run that didn't shut down cleanly.
try? fileManager.removeItem(at: socketURL)

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data("graphcoded: \(message)\n".utf8))
  exit(1)
}

#if canImport(Darwin)
  let socketDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
#else
  // Glibc imports SOCK_STREAM as the `__socket_type` enum, not an Int32.
  let socketDescriptor = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
#endif
guard socketDescriptor >= 0 else {
  fail("failed to create socket (errno \(errno))")
}

var address = sockaddr_un()
address.sun_family = sa_family_t(AF_UNIX)
#if canImport(Darwin)
  address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
#endif

let path = socketURL.path
withUnsafeMutablePointer(to: &address.sun_path) { pathField in
  pathField.withMemoryRebound(
    to: CChar.self, capacity: MemoryLayout.size(ofValue: pathField.pointee)
  ) { pathPointer in
    _ = path.withCString { cPath in
      strncpy(pathPointer, cPath, MemoryLayout.size(ofValue: pathField.pointee) - 1)
    }
  }
}

let bindResult = withUnsafePointer(to: &address) { addressPointer -> Int32 in
  addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rawPointer in
    bind(socketDescriptor, rawPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
  }
}
guard bindResult == 0 else {
  fail("failed to bind \(path) (errno \(errno))")
}

guard listen(socketDescriptor, 8) == 0 else {
  fail("failed to listen on \(path) (errno \(errno))")
}

// The diagnostics file, opened before the first line worth keeping. Stdout and stderr
// move onto it (launchd pointed them at the same file, unbounded), so from here every
// line the daemon writes is timestamped, structured, and rotated.
DaemonLog.shared.open(directory: supportDirectory)
DaemonLog.shared.record(
  "startup",
  [
    ("pid", String(getpid())),
    ("version", DaemonIdentity.version),
    ("build", DaemonIdentity.build),
    ("executable", CommandLine.arguments[0]),
    ("support", supportDirectory.path),
    ("socket", path),
  ])

// A broadcast writes to every connected client, and a client can vanish without a
// clean close — the app killed, a CLI exiting early, a pane crashing. The write then
// raises SIGPIPE, whose default action *terminates the daemon*: observed as exit
// status -13 in `launchctl list`, with every loop's in-flight send failing until
// launchd restarted the process seconds later.
//
// Ignoring it turns that into what the code already handles correctly:
// `FramedMessageIO.writeAll` sees write() return -1/EPIPE, throws, and
// `GraphStore.send` drops the dead connection. The error path was always right; the
// process just never lived long enough to run it.
signal(SIGPIPE, SIG_IGN)

// Termination is handled on the main queue, not in signal context (#167). The handlers
// this replaces called `exit(0)` from inside the signal handler itself, and `exit` is
// not async-signal-safe: it runs atexit and runtime teardown after interrupting whatever
// thread happened to be running — which can be a thread mid-`malloc` or mid-`write`,
// holding exactly the locks teardown needs. An idle daemon died cleanly in milliseconds
// every time; a busy one could deadlock until launchd's ExitTimeOut escalated to
// SIGKILL, observed as `launchctl bootout` taking ~29 seconds while a workspace was
// being deleted. A dispatch signal source delivers the signal as an ordinary work item,
// where `exit` is just a function call.
//
// `SIG_IGN` first, so the default terminate-without-cleanup disposition can't win the
// race before the sources are resumed.
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)

func makeShutdownSource(for signalNumber: Int32) -> DispatchSourceSignal {
  let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
  source.setEventHandler {
    unlink(path)
    exit(0)
  }
  source.resume()
  return source
}

// Top-level lets, so the sources outlive this file's execution — a released source
// stops delivering, and the signal falls back to the ignored disposition above, which
// would make the daemon *unkillable* by SIGTERM instead of slow.
let terminateSource = makeShutdownSource(for: SIGTERM)
let interruptSource = makeShutdownSource(for: SIGINT)

// Notice the binary being swapped underneath this process and get out of its way
// (#199). `DaemonBootstrap` boots a stale daemon out only from the app, at launch, for
// the current workspace — every path that misses that call (an update whose relaunch
// never happened, a workspace whose window stays closed) left an old daemon running old
// code under `KeepAlive` indefinitely; the pre-0.1.44 PTY leak survived weeks of
// upgrades exactly this way. The install lands a fresh inode, so one `stat` a minute
// answers the question, and exiting cleanly is enough: `KeepAlive` respawns the path,
// which is now the new binary. A launch identity that cannot be read (a relative
// argv[0] from a hand launch) disables the check rather than arming a wrong one, and a
// transient unreadable tick — the rename window mid-install — is skipped, not obeyed.
func makeStalenessTimer() -> DispatchSourceTimer? {
  let executablePath = CommandLine.arguments[0]
  guard let launchIdentity = ExecutableIdentity.of(path: executablePath) else { return nil }
  let timer = DispatchSource.makeTimerSource(queue: .main)
  timer.schedule(deadline: .now() + 60, repeating: 60)
  timer.setEventHandler {
    guard let current = ExecutableIdentity.of(path: executablePath), current != launchIdentity
    else { return }
    DaemonLog.shared.record("shutdown", [("reason", "binary-replaced")])
    unlink(path)
    exit(0)
  }
  timer.resume()
  return timer
}

let stalenessTimer = makeStalenessTimer()

let registry = ProjectRegistry(
  persistenceDirectory: supportDirectory,
  reapCondemnedSessions: true)

/// Bridges a blocking socket read onto a background queue so the `Task` awaiting it
/// never blocks Swift concurrency's cooperative thread pool — the whole connection
/// handler below is otherwise just async/await hops (this, plus actor calls).
@Sendable func readFrameAsync(from fileDescriptor: Int32) async throws -> Data {
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

/// A counter safe to bump from the accept loop's thread while connection tasks read it.
final class ManagedAtomic: @unchecked Sendable {
  private var value: Int
  private let lock = NSLock()
  init(_ value: Int) { self.value = value }
  func next() -> Int {
    lock.lock()
    defer { lock.unlock() }
    value += 1
    return value
  }
}

/// Numbers connections in the order they arrived — the `conn` every line about one
/// carries, short enough to read and stable for the daemon's lifetime.
let connectionCounter = ManagedAtomic(0)

func handleConnection(_ fileDescriptor: Int32) {
  Task {
    let connectionID = UUID()
    let connection = connectionCounter.next()
    let peer = SocketPeer.pid(of: fileDescriptor)
    let connected = Date()
    // `addConnection` opens this connection's outbound channel as it registers it.
    await registry.addConnection(id: connectionID, fileDescriptor: fileDescriptor)
    // `peer` is the client's pid: what a `graphcode` invocation prints when it times
    // out, so its complaint and these lines can be matched up with no id on the wire.
    DaemonLog.shared.record(
      "connect",
      [
        ("conn", String(connection)), ("fd", String(fileDescriptor)),
        ("peer", peer.map(String.init) ?? "?"),
      ])
    var sequence = 0
    var requests = 0
    while true {
      let data: Data
      do {
        data = try await readFrameAsync(from: fileDescriptor)
      } catch {
        break
      }
      sequence += 1
      let received = Date()
      let request = DaemonRequestContext.Request(connection: connection, sequence: sequence)
      do {
        let command = try JSONDecoder().decode(DaemonCommand.self, from: data)
        let decoded = Date()
        await DaemonRequestContext.$current.withValue(request) {
          await registry.handle(command, connectionID: connectionID)
        }
        requests += 1
        // The request's own line: what kind, how big, and how long each phase took.
        // Never the payload — a `graphCommand.memoNode` is logged as exactly that.
        DaemonLog.shared.record(
          "request",
          [
            ("conn", String(connection)), ("seq", String(sequence)),
            ("kind", command.kindName), ("bytes", String(data.count)),
            ("decode_ms", DaemonLog.milliseconds(decoded.timeIntervalSince(received))),
            ("handle_ms", DaemonLog.milliseconds(Date().timeIntervalSince(decoded))),
          ])
      } catch {
        DaemonLog.shared.record(
          "request",
          [
            ("conn", String(connection)), ("seq", String(sequence)), ("kind", "undecodable"),
            ("bytes", String(data.count)),
          ])
        // A frame that read fine but didn't decode is version skew, not a dead socket:
        // a newer CLI sent a command this daemon predates. Dropping the connection here
        // failed *silently* — the client just saw a hang-up — so answer instead and
        // keep serving the commands this daemon does understand.
        let event = DaemonEvent.errorOccurred(
          "unrecognized command — graphcoded may be older than the client that sent it")
        if let encoded = try? JSONEncoder().encode(event) {
          OutboundChannels.send(encoded, to: fileDescriptor)
        }
      }
    }
    await registry.removeConnection(connectionID)
    // The channel owns the descriptor now: closing it here would free a number the
    // kernel can hand straight to the next `accept` while a write is still in flight on
    // it. `close` tears the socket down, which is also what unblocks a writer parked on a
    // peer that stopped reading.
    OutboundChannels.close(fileDescriptor)
    DaemonLog.shared.record(
      "disconnect",
      [
        ("conn", String(connection)), ("fd", String(fileDescriptor)),
        ("requests", String(requests)),
        ("lifetime_ms", DaemonLog.milliseconds(Date().timeIntervalSince(connected))),
      ])
  }
}

DispatchQueue.global().async {
  while true {
    let clientDescriptor = accept(socketDescriptor, nil, nil)
    guard clientDescriptor >= 0 else { continue }
    // Belt and braces beside the process-wide ignore above: this socket raises no
    // SIGPIPE whatever any library does to the signal disposition later.
    #if canImport(Darwin)
      var noSignal: Int32 = 1
      setsockopt(
        clientDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    #endif
    handleConnection(clientDescriptor)
  }
}

dispatchMain()
