import Foundation

/// What the app (or, eventually, the `graphcode` CLI) can ask `graphcoded` to do. See
/// docs/03-architecture.md#background-daemons and
/// docs/07-roadmap.md#phase-3--orchestrator-automation.
///
/// Deliberately thin: creating a node/edge or resolving a turn-based check are the only
/// mutations Phase 3 needs. There's no `deleteNode`/`updateGraph` — not because they're
/// hard, but because nothing in the app needs them yet, and a wire protocol is easier
/// to extend than to narrow.
public enum DaemonCommand: Codable, Sendable, Equatable {
  case createTurnBasedNode(title: String, checkDescription: String)
  case createTimeBasedNode(title: String, intervalSeconds: Double, prompt: String)
  case createEdge(from: UUID, to: UUID)
  case nodeCheckApproved(UUID)
  case nodeCheckRejected(UUID)
}

/// What `graphcoded` pushes back — to the client that sent a command and to every
/// other connected client, so two open windows (or the app plus a future CLI) never
/// disagree about graph state. `graphChanged` always carries the *full* graph rather
/// than a diff: simplest possible thing that keeps every client in sync, and small
/// enough at this scale that a diff protocol isn't worth the complexity yet.
public enum DaemonEvent: Codable, Sendable, Equatable {
  case graphChanged(LoopGraph)
  case errorOccurred(String)
}
