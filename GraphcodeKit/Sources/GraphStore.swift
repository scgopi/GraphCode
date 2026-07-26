import Foundation

/// Owns the daemon's one `LoopGraph`, applies commands, automatically fires `.handoff`
/// edges when a node resolves, arms/runs time-based triggers, and broadcasts the
/// updated graph to every connected client. This is the whole of what makes
/// `graphcoded` load-bearing from Phase 3 on — see
/// docs/07-roadmap.md#phase-3--orchestrator-automation.
///
/// Lives in `GraphcodeKit`, not `graphcoded/Sources`, even though only the daemon
/// instantiates it in production: it has no socket/process-lifecycle coupling of its
/// own (connections are just `[UUID: Int32]` file descriptors handed to it), so it's
/// cleanly unit-testable from `graphcodeTests` without spinning up a real daemon
/// process or socket.
///
/// No `.global` Orchestrator Graph yet (still deferred, see `LoopGraph`'s doc comment)
/// and no persistence to disk — the graph lives in memory for as long as `graphcoded`
/// runs. Losing it on daemon restart is an accepted gap for this phase, not something
/// Phase 3 claims to solve.
public actor GraphStore {
  public private(set) var graph: LoopGraph
  private var connections: [UUID: Int32] = [:]
  private var timers: [UUID: Task<Void, Never>] = [:]

  public init(graph: LoopGraph = LoopGraph(title: "My first graph")) {
    self.graph = graph
  }

  // MARK: - Connections

  public func addConnection(fileDescriptor: Int32) -> UUID {
    let id = UUID()
    connections[id] = fileDescriptor
    send(.graphChanged(graph), to: id)
    return id
  }

  public func removeConnection(_ id: UUID) {
    connections.removeValue(forKey: id)
  }

  // MARK: - Commands

  public func handle(_ command: DaemonCommand) {
    switch command {
    case .createTurnBasedNode(let title, let checkDescription):
      let node = LoopNode(title: title, loopType: .turnBased, checkDescription: checkDescription)
      graph.nodes.append(node)

    case .createTimeBasedNode(let title, let intervalSeconds, let prompt):
      let node = LoopNode(
        title: title, loopType: .timeBased, triggerIntervalSeconds: intervalSeconds,
        triggerPrompt: prompt)
      graph.nodes.append(node)
      armTimer(for: node.id, intervalSeconds: intervalSeconds)

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

  // MARK: - Scheduler (time-based nodes)

  /// Arms a repeating trigger for a time-based node. This `Task` is owned by
  /// `graphcoded`, not the app — it keeps firing on schedule whether or not any client
  /// is connected, which is the entire point of Phase 3 (see
  /// docs/03-architecture.md#why-a-daemon-at-all). First fire is after one interval,
  /// matching ordinary cron/interval semantics (not immediately on creation).
  private func armTimer(for nodeID: UUID, intervalSeconds: Double) {
    timers[nodeID] = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(intervalSeconds))
        guard !Task.isCancelled else { return }
        await self?.fireTimeBasedNode(nodeID)
      }
    }
  }

  private func fireTimeBasedNode(_ nodeID: UUID) async {
    guard let node = graph.nodes[id: nodeID] else { return }
    graph.nodes[id: nodeID]?.state = .running
    broadcast()

    let succeeded: Bool
    do {
      // Non-interactive (`claude -p`), not a bare interactive session: nobody's
      // present to hold up a conversation with a headless trigger, so it needs an
      // actual task to run to completion. The prompt is passed via environment
      // variable, not interpolated into the shell command string, so a prompt
      // containing quotes/special characters can't break out of the command.
      let session = try PTYProcessSession(
        arguments: ["-l", "-c", "exec claude -p \"$GRAPHCODE_TRIGGER_PROMPT\""],
        workingDirectory: node.worktreeBinding?.worktreePath,
        extraEnvironment: ["GRAPHCODE_TRIGGER_PROMPT": node.triggerPrompt ?? "Say hello."]
      )
      succeeded = await session.waitUntilFinished()
    } catch {
      succeeded = false
    }

    resolveNode(nodeID, succeeded: succeeded)
    broadcast()
  }

  // MARK: - Broadcast

  private func broadcast() {
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
