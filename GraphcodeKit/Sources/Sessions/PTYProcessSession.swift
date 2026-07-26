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
  private let masterHandle: FileHandle
  private let eventContinuation: AsyncStream<PTYSessionEvent>.Continuation

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

    let masterHandle = FileHandle(fileDescriptor: master, closeOnDealloc: true)
    let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
    self.masterHandle = masterHandle

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
    // If graphcode.app/graphcoded was itself launched from inside a live Claude Code
    // session, these identity vars are already set in *our* environment and would
    // otherwise leak into every `claude` process we spawn — making it think it's a
    // spawned child/subagent session (transcript saving off, etc.) when it's really a
    // fresh top-level session the user is starting in this terminal.
    for key in environment.keys where key.hasPrefix("CLAUDE") || key == "AI_AGENT" {
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

    try process.run()
    // The child has its own copy of the slave fd now; close ours so EOF on the
    // master side is detectable once the child exits.
    close(slave)

    masterHandle.readabilityHandler = { handle in
      let data = handle.availableData
      guard !data.isEmpty else { return }
      if let text = String(data: data, encoding: .utf8) {
        continuation.yield(.output(text))
      }
    }

    process.terminationHandler = { [weak self] process in
      self?.masterHandle.readabilityHandler = nil
      continuation.yield(.terminated(succeeded: process.terminationStatus == 0))
      continuation.finish()
    }
  }

  public func sendInput(_ text: String) {
    guard let data = text.data(using: .utf8) else { return }
    masterHandle.write(data)
  }

  public func terminate() {
    if process.isRunning {
      process.terminate()
    }
  }

  /// Runs the process to completion headlessly (no live interaction) — what
  /// `graphcoded` uses for a time-based node's trigger, where there's no human present
  /// to read output or type input. Returns once `.terminated` arrives.
  public func waitUntilFinished() async -> Bool {
    var succeeded = false
    for await event in events {
      if case .terminated(let didSucceed) = event {
        succeeded = didSucceed
      }
    }
    return succeeded
  }
}
