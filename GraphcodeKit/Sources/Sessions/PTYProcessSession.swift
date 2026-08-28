import Darwin
import Foundation

/// One event out of a running PTY-backed process: either a chunk of raw output, or a
/// terminal lifecycle transition. See docs/04-cli-backends.md.
public enum PTYSessionEvent: Sendable, Equatable {
  case output(String)
  case terminated(succeeded: Bool)
}

/// A CLI process attached to a real PTY — the shared primitive both the app's
/// interactive `CLISessionClient` and `graphcoded`'s headless time-based launches use
/// to spawn `claude`. Extracted from Phase 1's `CLISessionClient` so both sides launch
/// processes the exact same way instead of maintaining two copies of `openpty`
/// bookkeeping.
///
/// **Interim implementation** (unchanged from Phase 1's rationale): this spawns the
/// process directly via `Process`, not through `zmx` — so a session doesn't survive
/// its owning process (`graphcode.app` or `graphcoded`) restarting. `graphcoded` itself
/// *does* survive app restarts, which is what Phase 3 actually needs; true
/// session-survives-a-crash persistence is still the deferred zmx swap-in from
/// docs/07-roadmap.md.
public final class PTYProcessSession: @unchecked Sendable {
  public let id = UUID()
  public let events: AsyncStream<PTYSessionEvent>

  private let process: Process
  private let master: MasterHandle
  private let eventContinuation: AsyncStream<PTYSessionEvent>.Continuation

  /// `Process.terminationHandler` may outlive the session and Foundation can retain the
  /// process while that callback is installed. Keep fd closure independent of ARC and
  /// idempotent so both `terminate()` and the natural-exit callback can safely call it.
  private final class MasterHandle: @unchecked Sendable {
    let fileHandle: FileHandle
    private let lock = NSLock()
    private var closed = false

    init(fileDescriptor: Int32) {
      fileHandle = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: true)
    }

    var isClosed: Bool {
      lock.lock()
      defer { lock.unlock() }
      return closed
    }

    func close() {
      lock.lock()
      guard !closed else {
        lock.unlock()
        return
      }
      closed = true
      lock.unlock()
      fileHandle.readabilityHandler = nil
      fileHandle.closeFile()
    }
  }

  public enum SessionError: Error, Equatable {
    case failedToOpenPTY
  }

  public init(
    executable: String = "/bin/zsh",
    arguments: [String] = ["-l", "-c", "exec claude"],
    workingDirectory: String? = nil,
    extraEnvironment: [String: String] = [:]
  ) throws {
    var master: Int32 = 0
    var slave: Int32 = 0
    guard openpty(&master, &slave, nil, nil, nil) == 0 else {
      throw SessionError.failedToOpenPTY
    }

    let masterHandle = MasterHandle(fileDescriptor: master)
    let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
    self.master = masterHandle

    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    if let workingDirectory {
      process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
    }
    process.standardInput = slaveHandle
    process.standardOutput = slaveHandle
    process.standardError = slaveHandle
    var environment = ProcessInfo.processInfo.environment
    // Belt and braces: the app and the daemon each scrub these at startup, but a
    // GraphcodeKit client that doesn't must still not leak them into a backend.
    for key in environment.keys where AgentEnvironment.isInheritedAgentIdentity(key) {
      environment.removeValue(forKey: key)
    }
    environment["TERM"] = "xterm-256color"
    for (key, value) in extraEnvironment {
      environment[key] = value
    }
    process.environment = environment
    self.process = process

    let (stream, continuation) = AsyncStream<PTYSessionEvent>.makeStream()
    self.events = stream
    self.eventContinuation = continuation

    do {
      try process.run()
    } catch {
      // A launch that never happened still allocated a PTY pair, and the slave half is
      // ours alone to close — leaving it open pins a `/dev/ttys*` for the lifetime of the
      // process, which for `graphcoded` means until the machine reboots. `kern.tty.ptmx_max`
      // is 511, so a caller whose launch reliably fails exhausts the host's PTYs outright.
      close(slave)
      masterHandle.close()
      continuation.finish()
      throw error
    }
    // The child has its own copy of the slave fd now; close ours so EOF on the
    // master side is detectable once the child exits.
    close(slave)

    masterHandle.fileHandle.readabilityHandler = { handle in
      let data = handle.availableData
      guard !data.isEmpty else { return }
      if let text = String(data: data, encoding: .utf8) {
        continuation.yield(.output(text))
      }
    }

    process.terminationHandler = { [weak masterHandle] process in
      guard let masterHandle else { return }
      // Detach the async reader first so the drain below is the only consumer left.
      masterHandle.fileHandle.readabilityHandler = nil
      // Termination is observed on a different queue than readability, so a process
      // that writes and immediately exits usually beats the reader to the finish line —
      // whatever is still in the PTY buffer was dropped here, and the stream closed
      // without it. That is how every fast metric script (`echo 7; exit`) read as
      // "printed no number" while slow `zmx` queries mostly survived: the race, not the
      // output, decided. Everything the child wrote before exiting is already in the
      // kernel buffer by the time this handler runs, so a non-blocking drain to
      // EOF/EAGAIN is complete — and non-blocking matters, because a grandchild that
      // inherited the slave fd could otherwise wedge this handler forever.
      if !masterHandle.isClosed {
        let descriptor = masterHandle.fileHandle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
          let count = read(descriptor, &buffer, buffer.count)
          guard count > 0 else { break }
          if let text = String(bytes: buffer[0..<count], encoding: .utf8) {
            continuation.yield(.output(text))
          }
        }
      }
      masterHandle.close()
      continuation.yield(.terminated(succeeded: process.terminationStatus == 0))
      continuation.finish()
      process.terminationHandler = nil
    }
  }

  deinit {
    process.terminationHandler = nil
    master.close()
    if process.isRunning { process.terminate() }
    eventContinuation.finish()
  }

  public func sendInput(_ text: String) {
    guard let data = text.data(using: .utf8) else { return }
    try? master.fileHandle.write(contentsOf: data)
  }

  public func terminate() {
    master.close()
    if process.isRunning {
      process.terminate()
      let processID = process.processIdentifier
      DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [weak process] in
        guard process?.isRunning == true else { return }
        _ = kill(processID, SIGKILL)
      }
    }
  }

  /// Runs the process to completion headlessly (no live interaction) — what
  /// `graphcoded` uses for a time-based node's trigger, where there's no human present
  /// to read output or type input. Returns once `.terminated` arrives.
  public func waitUntilFinished() async -> Bool {
    await waitCollectingOutput().succeeded
  }

  /// Same, but keeps what the process printed. Needed for the `zmx` queries whose
  /// *answer* is on stdout rather than in the exit status — reading a session's presence
  /// label, for one.
  public func waitCollectingOutput() async -> (succeeded: Bool, output: String) {
    var succeeded = false
    var output = ""
    for await event in events {
      switch event {
      case .output(let chunk):
        output += chunk
      case .terminated(let didSucceed):
        succeeded = didSucceed
      }
    }
    return (succeeded, output)
  }
}
