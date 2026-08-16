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
  /// Reopen whichever projects were showing in the sidebar when the app last quit. Sent
  /// at launch and again on every reconnect — joining is per-connection, so a client that
  /// dialled again is joined to nothing until it asks a second time. The daemon replies
  /// with one `.graphChanged` per project, which is exactly what `.openProject` produces,
  /// so the app needs no separate restore path.
  case restoreOpenProjects
  /// Join the one always-resident global Orchestrator Graph. It arrives as an ordinary
  /// `.graphChanged` like any project's, distinguishable by its reserved
  /// `graphcode://global` path.
  case openGlobalGraph
  /// Drop a project from the sidebar, keeping it in recents so Add Folder can bring it
  /// straight back.
  case closeProject(path: String)
  /// Close it *and* forget it from recents. The saved graph survives — re-opening the
  /// same folder restores its loops.
  case forgetProject(path: String)
  /// Discard a project's saved loops entirely. Irreversible, and separate from
  /// `forgetProject` precisely because it is.
  case deleteProjectGraph(path: String)
  case graphCommand(projectPath: String, command: GraphCommand)
}

/// Mutations against exactly one project's graph — this is what `GraphStore.handle`
/// takes, and (before Phase 4) was itself called `DaemonCommand`. Deliberately thin:
/// each case is a mutation something in the app actually reaches for. There's still no
/// general `updateGraph` — not because it's hard, but because nothing needs it yet, and
/// a wire protocol is easier to extend than to narrow. `renameNode` is the shape a
/// further per-field edit should follow rather than the first argument for a
/// catch-all: one named command says what changed, so the daemon can decide what a
/// change of *that* field means.
/// `indirect` because `.subGraphCommand` nests a `GraphCommand` inside itself — a
/// composite node's sub-graph takes exactly the same commands its parent graph does,
/// which is the point: there's no second execution engine, just the orchestrator running
/// a graph inside a graph (docs/05-orchestrator.md#responsibilities item 6).
public indirect enum GraphCommand: Codable, Sendable, Equatable {
  /// One command for every loop type — see `NodeDraft` for why the three type-specific
  /// create commands collapsed into this. An invalid draft is rejected by the daemon,
  /// not silently turned into a half-configured node.
  ///
  /// Note what a time-based draft does *not* carry: an interval. That cadence lives
  /// inside the node's own session, written into its prompt as a `/loop`/`/schedule`
  /// directive (see `LoopNode.triggerPrompt`).
  case createNode(NodeDraft)
  /// `spec` carries what the canvas's edge drop editor collected — kind, condition,
  /// payload transform (docs/06-ux-terminals.md#creating-edges). `EdgeSpec()`'s
  /// defaults reproduce the plain always-firing `.handoff` every edge was before the
  /// editor existed.
  case createEdge(from: UUID, to: UUID, spec: EdgeSpec)
  case nodeCheckApproved(UUID)
  case nodeCheckRejected(UUID)
  /// Give a loop a new title. Only the title — a loop's identity is its `id` (which is
  /// also its `zmx` session name, see `SurfaceRef`), so renaming touches nothing the
  /// session, its edges, or its persistence are keyed on. A running loop keeps running
  /// under the new name.
  ///
  /// An empty or whitespace-only title is refused rather than applied: the graph, the
  /// sidebar, and the canvas would all render a nameless card, and there is no undo.
  case renameNode(UUID, title: String)
  /// Edit a live loop's configuration — the partial-edit counterpart to `renameNode`,
  /// carrying only the fields being changed (`NodeUpdate`). Observer-side fields
  /// (predicate, intervals, metric) apply immediately; session-facing ones (goal
  /// summary, prompt, check) are nudged into a live session and recorded in the node's
  /// memory for its next wake. A loop may not change its *own* stop condition.
  case updateNode(UUID, update: NodeUpdate)
  /// Give a sketch a shape — goal, turn or timed — keeping everything else it is:
  /// same id, same session, same edges, same memory. A mutation on the existing node,
  /// never a create + delete, so anything keyed on the node's id survives untouched.
  /// Refused for any node that isn't a sketch; demotion has no wire shape at all
  /// (`SketchPromotion` carries no `.sketch` case).
  case promoteNode(UUID, promotion: SketchPromotion)
  /// Append a learned note to a node's memory log (`NodeMemory`) — what `graphcode
  /// node memo` rides on. `from` is attributed the same way `messageNode`'s is.
  case memoNode(UUID, text: String, from: UUID?)
  /// Type a message into a node's live session, right now — the ad-hoc counterpart to
  /// a `.message` edge, sharing its transport and its deliverability rules
  /// (`MessageBus`). This is what `graphcode node send` rides on, and its reason to
  /// exist is loops talking to *each other*: an edge is a standing relationship a human
  /// drew in advance, where this is one loop deciding mid-run that a peer should know
  /// something. `from` is the sending loop when the CLI could attribute it
  /// (`ZMX_SESSION`, the same mechanism as `NodeDraft.createdBy`), so the target sees
  /// who's talking; nil from a human's shell.
  case messageNode(UUID, text: String, from: UUID?)
  /// Removes the node, every edge touching it, and its detached session. Irreversible
  /// — the app confirms before sending this.
  case deleteNode(UUID)
  case deleteEdge(UUID)
  /// Stop a running loop from the monitor: it resolves to `.stopped` and its session is
  /// asked to stop looping (`MessageBus.stopRequest`), keeping the transcript and the
  /// agent alive. The session is only killed when it can't be reached to be asked. The
  /// node itself stays in the graph — stopping is not deleting.
  case stopNode(UUID)
  /// Route a command into a composite node's sub-graph. Editing a composite's insides is
  /// the same set of operations as editing any graph, so it reuses them wholesale rather
  /// than growing a parallel vocabulary.
  case subGraphCommand(nodeID: UUID, command: GraphCommand)
  /// Dry-run a composite node's sub-graph once, before its real trigger is armed
  /// (docs/08-quality-and-token-budgets.md#managing-token-usage).
  case pilotComposite(UUID)
  /// Arm a piloted composite node against its live trigger. Refused unless it has
  /// actually been piloted — that refusal is the whole safety mechanism.
  case armComposite(UUID)
  /// Pull fresh usage readings for every node from their backends. Explicit rather than
  /// polled: it costs a subprocess per session, and nobody needs it except while the
  /// usage panel is open.
  case refreshUsage
  /// Splice loops read out of an export bundle into this graph — see
  /// `GraphImportRequest` for why the daemon, not the client, performs the merge.
  case importNodes(GraphImportRequest)
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
