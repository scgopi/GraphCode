import Foundation

/// Owns the daemon's one `LoopGraph`, applies commands, automatically fires `.handoff`
/// edges when a node resolves, keeps time-based nodes' sessions alive, and broadcasts
/// the updated graph to every connected client. This is the whole of what makes
/// `graphcoded` load-bearing from Phase 3 on — see
/// docs/07-roadmap.md#phase-3--orchestrator-automation.
///
/// Note what this deliberately does *not* do: schedule anything. An earlier version ran
/// a `Task.sleep` timer per time-based node and fired a headless `claude -p` on each
/// tick, discarding the output — which left a human nothing to attach to, watch, or
/// steer. Recurrence now lives inside the session itself (`/loop` in the node's own
/// prompt, see `LoopNode.triggerPrompt`), so this store's only remaining job for a
/// time-based node is making sure its session exists.
///
/// Lives in `GraphcodeKit`, not `graphcoded/Sources`, even though only the daemon
/// instantiates it in production: it has no socket/process-lifecycle coupling of its
/// own (connections are just `[UUID: Int32]` file descriptors handed to it), so it's
/// cleanly unit-testable from `graphcodeTests` without spinning up a real daemon
/// process or socket.
///
/// No `.global` Orchestrator Graph yet (still deferred, see `LoopGraph`'s doc comment).
/// This actor itself still has no persistence of its own — from Phase 4 on that's
/// `ProjectRegistry`'s job, via the `onGraphChanged` hook below, since `GraphStore`
/// owns exactly one graph and has no notion of "which project" it belongs to.
///
/// Connection identity (the `id: UUID` `addConnection`/`removeConnection` take) is now
/// caller-supplied rather than generated here — `ProjectRegistry` owns one `UUID` per
/// live socket end-to-end across every project it might join over that socket's
/// lifetime, so it needs to be the one minting it.
public actor GraphStore {
  public private(set) var graph: LoopGraph
  private var connections: [UUID: Int32] = [:]
  private let onGraphChanged: (@Sendable (LoopGraph) -> Void)?
  private let onEnsureSession: (@Sendable (LoopNode) -> Void)?

  /// `onEnsureSession` is how a time-based node's session gets started without this
  /// actor knowing anything about `zmx` or spawning processes — same injected-closure
  /// idiom as `onGraphChanged`, and for the same reason: `GraphStore` stays unit-testable
  /// with no daemon, no socket, and no child process. `graphcoded` wires it to
  /// `ZmxSessionLauncher`; tests leave it `nil` or capture the calls.
  public init(
    graph: LoopGraph = LoopGraph(project: ProjectRef(path: "", name: "Untitled")),
    onGraphChanged: (@Sendable (LoopGraph) -> Void)? = nil,
    onEnsureSession: (@Sendable (LoopNode) -> Void)? = nil
  ) {
    self.graph = graph
    self.onGraphChanged = onGraphChanged
    self.onEnsureSession = onEnsureSession
  }

  // MARK: - Connections

  public func addConnection(id: UUID, fileDescriptor: Int32) {
    connections[id] = fileDescriptor
    send(.graphChanged(graph), to: id)
  }

  public func removeConnection(_ id: UUID) {
    connections.removeValue(forKey: id)
  }

  // MARK: - Commands

  public func handle(_ command: GraphCommand) {
    switch command {
    case .createTurnBasedNode(let title, let checkDescription):
      let node = LoopNode(title: title, loopType: .turnBased, checkDescription: checkDescription)
      graph.nodes.append(node)

    case .createTimeBasedNode(let title, let prompt):
      let node = LoopNode(title: title, loopType: .timeBased, triggerPrompt: prompt)
      graph.nodes.append(node)
      // Start it now rather than waiting for someone to open it — the loop is supposed
      // to run whether or not the app is up, which is the whole reason `graphcoded`
      // exists (docs/03-architecture.md#background-daemons).
      onEnsureSession?(node)

    case .createEdge(let from, let to):
      guard from != to, graph.nodes[id: from] != nil, graph.nodes[id: to] != nil,
        !graph.edges.contains(where: { $0.from == from && $0.to == to })
      else { return }
      graph.edges.append(LoopEdge(from: from, to: to))
      unblockIfStillIdle(to)

    case .nodeCheckApproved(let nodeID):
      resolveNode(nodeID, succeeded: true)

    case .nodeCheckRejected(let nodeID):
      resolveNode(nodeID, succeeded: false)
    }

    broadcast()
  }

  // MARK: - Resolution + automatic edge firing

  private func resolveNode(_ nodeID: UUID, succeeded: Bool) {
    guard graph.nodes[id: nodeID] != nil else { return }
    graph.nodes[id: nodeID]?.state = succeeded ? .succeeded : .failed
    fireOutgoingEdges(from: nodeID, sourceSucceeded: succeeded)
  }

  /// The Phase 3 half of docs/07-roadmap.md's "automatic edge evaluation and firing":
  /// evaluates every unfired outgoing `.handoff` edge's `EdgeCondition` against how the
  /// source node resolved, firing the ones that match and unblocking their targets.
  private func fireOutgoingEdges(from nodeID: UUID, sourceSucceeded: Bool) {
    let outgoing = graph.edges.filter { $0.from == nodeID && $0.kind == .handoff && !$0.fired }
    for edge in outgoing {
      let shouldFire: Bool
      switch edge.condition {
      case .always: shouldFire = true
      case .onSuccess: shouldFire = sourceSucceeded
      case .onFailure: shouldFire = !sourceSucceeded
      }
      guard shouldFire else { continue }
      graph.edges[id: edge.id]?.fired = true
      unblockIfStillIdle(edge.to)
    }
  }

  private func unblockIfStillIdle(_ nodeID: UUID) {
    guard graph.nodes[id: nodeID]?.state == .idle || graph.nodes[id: nodeID]?.state == .blocked
    else { return }
    let stillBlocked = graph.edges.contains { $0.to == nodeID && $0.kind == .handoff && !$0.fired }
    graph.nodes[id: nodeID]?.state = stillBlocked ? .blocked : .idle
  }

  // MARK: - Time-based session liveness

  /// Makes sure every time-based node in this graph has its session running. Called
  /// when a persisted graph is first loaded (`ProjectRegistry.store(forProjectPath:)`),
  /// which is what gets loops going again after a reboot or a daemon restart — the
  /// session itself is long-lived, but nothing outside it would otherwise recreate it
  /// once it's gone.
  ///
  /// Safe to call repeatedly, but only because `ZmxSessionLauncher` checks for an
  /// existing session first — `zmx run` itself is *not* idempotent, and re-running it
  /// against a live session types the prompt in a second time.
  public func ensureTimeBasedSessions() {
    for node in graph.nodes where node.loopType == .timeBased {
      onEnsureSession?(node)
    }
  }

  // MARK: - Broadcast

  private func broadcast() {
    onGraphChanged?(graph)
    for id in connections.keys {
      send(.graphChanged(graph), to: id)
    }
  }

  private func send(_ event: DaemonEvent, to connectionID: UUID) {
    guard let fileDescriptor = connections[connectionID] else { return }
    guard let data = try? JSONEncoder().encode(event) else { return }
    guard (try? FramedMessageIO.writeFrame(data, to: fileDescriptor)) != nil else {
      // The write failed — most likely the client already disconnected. Drop it here
      // rather than waiting for the read loop to notice, so a dead connection can't
      // accumulate failed broadcast attempts.
      connections.removeValue(forKey: connectionID)
      return
    }
  }
}
