import Foundation

/// What the app (or, eventually, the `graphcode` CLI) can ask `graphcoded` to do. See
/// docs/03-architecture.md#background-daemons and
/// docs/07-roadmap.md#phase-4--projects.
///
/// From Phase 4 on `graphcoded` hosts more than one `LoopGraph` — one per opened
/// project — so every graph-mutating command is routed by `projectPath`. This is a
/// thin wrapper around `GraphCommand`, not a rewrite of it: `GraphStore` itself (which
/// owns exactly one graph) still only ever sees a bare `GraphCommand`, completely
/// unaware that multi-project routing exists one level up in `ProjectRegistry`.
public enum DaemonCommand: Codable, Sendable, Equatable {
  case listRecentProjects
  case openProject(path: String)
  case graphCommand(projectPath: String, command: GraphCommand)
}

/// Mutations against exactly one project's graph — this is what `GraphStore.handle`
/// takes, and (before Phase 4) was itself called `DaemonCommand`. Deliberately thin:
/// creating a node/edge or resolving a turn-based check are the only mutations built
/// so far. There's no `deleteNode`/`updateGraph` — not because they're hard, but
/// because nothing in the app needs them yet, and a wire protocol is easier to extend
/// than to narrow.
public enum GraphCommand: Codable, Sendable, Equatable {
  case createTurnBasedNode(title: String, checkDescription: String)
  case createTimeBasedNode(title: String, intervalSeconds: Double, prompt: String)
  case createEdge(from: UUID, to: UUID)
  case nodeCheckApproved(UUID)
  case nodeCheckRejected(UUID)
}

/// What `graphcoded` pushes back — to the client that sent a command and to every
/// other connected client subscribed to the same project, so two open windows never
/// disagree about that project's graph state. `graphChanged` always carries the *full*
/// graph rather than a diff: simplest possible thing that keeps every client in sync,
/// and small enough at this scale that a diff protocol isn't worth the complexity yet.
/// The graph's own `project` field is what tells a client which project a
/// `graphChanged` event belongs to — there's no separate "project opened" event,
/// because joining a project already gets one of these as an immediate snapshot (see
/// `GraphStore.addConnection`).
public enum DaemonEvent: Codable, Sendable, Equatable {
  case recentProjectsListed([ProjectRef])
  case graphChanged(LoopGraph)
  case errorOccurred(String)
}
