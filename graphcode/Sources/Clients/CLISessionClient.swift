import Darwin
import Dependencies
import Foundation

/// One event out of a running CLI session: either a chunk of raw terminal output, or
/// a lifecycle-derived state change. A single stream so a TCA `.run` effect only has
/// to observe one thing per session. See docs/04-cli-backends.md.
enum CLISessionEvent: Sendable, Equatable {
  case output(String)
  case stateChanged(LoopState)
}

struct CLISessionHandle: Sendable {
  let id: UUID
  let events: AsyncStream<CLISessionEvent>
}

/// Graphcode's own `CLISessionClient` — Claude Code only, per Phase 1 scope (see
/// docs/07-roadmap.md#phase-1--single-loop-manual-check).
///
/// **Interim implementation.** The real design (docs/04-cli-backends.md) has this
/// backed by `zmx`, so a session survives app quit and a `GhosttyKit` view can attach
/// to it. `zmx` isn't buildable in this environment yet (see docs/07-roadmap.md), so
/// this spawns `claude` directly in a PTY via `Process` — a real interactive session,
/// just not a persistent one. Swap the `liveValue` below for a zmx-backed
/// implementation once that's unblocked; the `CLISessionClient` surface itself
/// shouldn't need to change.
struct CLISessionClient: Sendable {
  var launch: @Sendable (_ node: LoopNode) async throws -> CLISessionHandle
  var sendInput: @Sendable (_ sessionID: UUID, _ text: String) async throws -> Void
  var terminate: @Sendable (_ sessionID: UUID) async -> Void
}

enum CLISessionClientError: Error, Equatable {
  case unsupportedBackend(CLISessionBackendKind)
  case failedToOpenPTY
  case sessionNotFound
}

extension CLISessionClient: DependencyKey {
  static let liveValue: CLISessionClient = {
    let registry = PTYSessionRegistry()
    return CLISessionClient(
      launch: { node in
        guard node.backend == .claudeCode else {
          throw CLISessionClientError.unsupportedBackend(node.backend)
        }
        return try await registry.launch(node: node)
      },
      sendInput: { sessionID, text in
        try await registry.sendInput(id: sessionID, text: text)
      },
      terminate: { sessionID in
        await registry.terminate(id: sessionID)
      }
    )
  }()
}

extension DependencyValues {
  var cliSessionClient: CLISessionClient {
    get { self[CLISessionClient.self] }
    set { self[CLISessionClient.self] = newValue }
  }
}

/// Owns the live PTY sessions so `sendInput`/`terminate` can look one back up by id.
private actor PTYSessionRegistry {
  private var sessions: [UUID: PTYSession] = [:]

  func launch(node: LoopNode) throws -> CLISessionHandle {
    let session = try PTYSession(workingDirectory: node.worktreeBinding?.worktreePath)
    sessions[session.id] = session
    return CLISessionHandle(id: session.id, events: session.events)
  }

  func sendInput(id: UUID, text: String) throws {
    guard let session = sessions[id] else { throw CLISessionClientError.sessionNotFound }
    session.sendInput(text)
  }

  func terminate(id: UUID) {
    sessions[id]?.terminate()
    sessions[id] = nil
  }
}

/// A single `claude` process attached to a real PTY. Not an actor itself (the
/// `Process`/`FileHandle` calls it makes are synchronous, fire-and-forget from the
/// registry's perspective) — `PTYSessionRegistry` is what serializes access.
private final class PTYSession: @unchecked Sendable {
  let id = UUID()
  let events: AsyncStream<CLISessionEvent>

  private let process: Process
  private let controllerHandle: FileHandle
  private let eventContinuation: AsyncStream<CLISessionEvent>.Continuation

  init(workingDirectory: String?) throws {
    var controllerFD: Int32 = 0
    var replicaFD: Int32 = 0
    guard openpty(&controllerFD, &replicaFD, nil, nil, nil) == 0 else {
      throw CLISessionClientError.failedToOpenPTY
    }

    let controllerHandle = FileHandle(fileDescriptor: controllerFD, closeOnDealloc: true)
    let replicaHandle = FileHandle(fileDescriptor: replicaFD, closeOnDealloc: false)
    self.controllerHandle = controllerHandle

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    // A login shell so `claude` resolves the same way it would in a real terminal
    // (mise/nvm/etc. shims live in profile-sourced PATH, not the app's inherited one).
    process.arguments = ["-l", "-c", "exec claude"]
    if let workingDirectory {
      process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
    }
    process.standardInput = replicaHandle
    process.standardOutput = replicaHandle
    process.standardError = replicaHandle
    var environment = ProcessInfo.processInfo.environment
    environment["TERM"] = "xterm-256color"
    process.environment = environment
    self.process = process

    let (stream, continuation) = AsyncStream<CLISessionEvent>.makeStream()
    self.events = stream
    self.eventContinuation = continuation

    try process.run()
    // The child has its own copy of the replica fd now; close ours so EOF on the
    // controller side is detectable once the child exits.
    close(replicaFD)

    continuation.yield(.stateChanged(.running))

    controllerHandle.readabilityHandler = { handle in
      let data = handle.availableData
      guard !data.isEmpty else { return }
      if let text = String(data: data, encoding: .utf8) {
        continuation.yield(.output(text))
      }
    }

    process.terminationHandler = { [weak self] process in
      self?.controllerHandle.readabilityHandler = nil
      continuation.yield(.stateChanged(process.terminationStatus == 0 ? .succeeded : .failed))
      continuation.finish()
    }
  }

  func sendInput(_ text: String) {
    guard let data = text.data(using: .utf8) else { return }
    controllerHandle.write(data)
  }

  func terminate() {
    if process.isRunning {
      process.terminate()
    }
  }
}
