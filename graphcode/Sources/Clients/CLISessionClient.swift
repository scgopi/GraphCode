import Dependencies
import Foundation
import GraphcodeKit

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

/// Graphcode's own `CLISessionClient` — Claude Code only (see docs/04-cli-backends.md).
/// Wraps the shared `PTYProcessSession` (`GraphcodeKit`) — the same primitive
/// `graphcoded` uses for headless time-based launches — for the interactive,
/// human-attended case: a real terminal a person is actively watching and typing into.
///
/// **Interim implementation**, per `PTYProcessSession`'s own doc comment: not zmx-backed
/// yet, so a session doesn't survive this process restarting. Swap this out once zmx is
/// unblocked; the `CLISessionClient` surface shouldn't need to change.
struct CLISessionClient: Sendable {
  var launch: @Sendable (_ node: LoopNode) async throws -> CLISessionHandle
  var sendInput: @Sendable (_ sessionID: UUID, _ text: String) async throws -> Void
  var terminate: @Sendable (_ sessionID: UUID) async -> Void
}

enum CLISessionClientError: Error, Equatable {
  case unsupportedBackend(CLISessionBackendKind)
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

/// Owns the live PTY sessions so `sendInput`/`terminate` can look one back up by id,
/// and adapts `PTYProcessSession`'s generic `PTYSessionEvent` to this client's
/// `CLISessionEvent` (which carries a full `LoopState`, not just success/failure).
private actor PTYSessionRegistry {
  private var sessions: [UUID: PTYProcessSession] = [:]

  func launch(node: LoopNode) throws -> CLISessionHandle {
    let session = try PTYProcessSession(workingDirectory: node.worktreeBinding?.worktreePath)
    sessions[session.id] = session

    let (stream, continuation) = AsyncStream<CLISessionEvent>.makeStream()
    continuation.yield(.stateChanged(.running))
    Task {
      for await event in session.events {
        switch event {
        case .output(let text):
          continuation.yield(.output(text))
        case .terminated(let succeeded):
          continuation.yield(.stateChanged(succeeded ? .succeeded : .failed))
          continuation.finish()
        }
      }
    }

    return CLISessionHandle(id: session.id, events: stream)
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
