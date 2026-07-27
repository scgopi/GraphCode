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
  private let onEnsureSession: (@Sendable (LoopNode, String?) -> Void)?
  private let onTerminateSession: (@Sendable (LoopNode) -> Void)?
  private let onEvaluatePredicate: (@Sendable (ShellPredicate) async -> Bool)?
  private let onDeliverMessage: (@Sendable (LoopNode, String) async -> Bool)?
  private let onCaptureScript: (@Sendable (ShellPredicate) async -> String?)?
  private let onReadUsage: (@Sendable (LoopNode) async -> UsageSample?)?
  /// Cross-graph `.spawn`. `GraphStore` owns exactly one graph and cannot reach another,
  /// so it hands the request up to `ProjectRegistry`, which is the layer that knows every
  /// open project — the same split that keeps this actor unaware multi-project routing
  /// exists at all.
  private let onSpawnIntoProject: (@Sendable (String, NodeDraft) -> Void)?
  private var goalPollers: [UUID: Task<Void, Never>] = [:]
  /// Guarded edges whose re-fire is waiting on an `until` predicate — see
  /// `fireOutgoingEdges`, drained by `handle` before it broadcasts.
  private var pendingCycleReentries: [UUID] = []
  /// `.message` edges whose delivery is waiting on a live-session check and possibly a
  /// script run — drained alongside cycle re-entries.
  private var pendingMessages: [UUID] = []
  /// Messages the orchestrator declined to deliver, newest last. Surfaced so an
  /// undelivered message is visible rather than silently dropped.
  public private(set) var undeliveredMessages:
    [(edgeID: UUID, reason: MessageBus.DeliveryFailure)] =
      []

  /// `onEnsureSession` is how a time-based node's session gets started without this
  /// actor knowing anything about `zmx` or spawning processes — same injected-closure
  /// idiom as `onGraphChanged`, and for the same reason: `GraphStore` stays unit-testable
  /// with no daemon, no socket, and no child process. `graphcoded` wires it to
  /// `ZmxSessionLauncher`; tests leave it `nil` or capture the calls.
  public init(
    graph: LoopGraph = LoopGraph(project: ProjectRef(path: "", name: "Untitled")),
    onGraphChanged: (@Sendable (LoopGraph) -> Void)? = nil,
    onEnsureSession: (@Sendable (LoopNode, String?) -> Void)? = nil,
    onTerminateSession: (@Sendable (LoopNode) -> Void)? = nil,
    onEvaluatePredicate: (@Sendable (ShellPredicate) async -> Bool)? = nil,
    onDeliverMessage: (@Sendable (LoopNode, String) async -> Bool)? = nil,
    onCaptureScript: (@Sendable (ShellPredicate) async -> String?)? = nil,
    onReadUsage: (@Sendable (LoopNode) async -> UsageSample?)? = nil,
    onSpawnIntoProject: (@Sendable (String, NodeDraft) -> Void)? = nil
  ) {
    self.graph = graph
    self.onGraphChanged = onGraphChanged
    self.onEnsureSession = onEnsureSession
    self.onTerminateSession = onTerminateSession
    self.onEvaluatePredicate = onEvaluatePredicate
    self.onDeliverMessage = onDeliverMessage
    self.onCaptureScript = onCaptureScript
    self.onReadUsage = onReadUsage
    self.onSpawnIntoProject = onSpawnIntoProject
  }

  /// Every session start goes through here rather than calling `onEnsureSession` directly,
  /// so no call site can forget the project path — and there are six of them, across node
  /// creation, composite piloting, spawning, and cycle re-entry.
  ///
  /// The path is where the session opens when the node has no worktree of its own. Without
  /// it a daemon-launched loop inherits `graphcoded`'s own directory, which under launchd
  /// is `/`, so the loop ran nowhere near the project it was created in.
  private func ensureSession(_ node: LoopNode) {
    onEnsureSession?(node, graph.project.path)
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

  public func handle(_ command: GraphCommand) async {
    switch command {
    case .createNode(let draft):
      // Validated here rather than only in the form: this protocol is reachable from the
      // CLI too, and a rule only one client enforces isn't a rule.
      guard draft.isValid else { return }
      let node = draft.makeNode()
      graph.nodes.append(node)
      if node.runsUnattended {
        // Start it now rather than waiting for someone to open it — the loop is supposed
        // to run whether or not the app is up, which is the whole reason `graphcoded`
        // exists (docs/03-architecture.md#background-daemons).
        ensureSession(node)
      }
      if node.loopType == .goalBased {
        armGoalPoller(for: node)
      }

    case .createEdge(let from, let to, let spec):
      // Duplicates are scoped per kind, not per pair: a `.handoff` and a `.message`
      // between the same two loops are different relationships (one sequences them,
      // one lets them talk mid-flight), so both are allowed to exist at once. Two
      // edges of the *same* kind between the same pair still collapse to one.
      guard from != to, graph.nodes[id: from] != nil, graph.nodes[id: to] != nil,
        !graph.edges.contains(where: { $0.from == from && $0.to == to && $0.kind == spec.kind })
      else { return }
      // A guard that bounds nothing would turn a cycle into an unattended infinite loop
      // spending tokens forever. Refused outright rather than silently dropped, so the
      // edge doesn't quietly become a one-shot when the human asked for a loop.
      if let cycleGuard = spec.cycleGuard, !cycleGuard.isBounded { return }
      graph.edges.append(LoopEdge(from: from, to: to, spec: spec))
      unblockIfStillIdle(to)

    case .nodeCheckApproved(let nodeID):
      resolveNode(nodeID, succeeded: true)

    case .nodeCheckRejected(let nodeID):
      resolveNode(nodeID, succeeded: false)

    case .deleteNode(let nodeID):
      deleteNode(nodeID)

    case .deleteEdge(let edgeID):
      deleteEdge(edgeID)

    case .stopNode(let nodeID):
      stopNode(nodeID)

    case .subGraphCommand(let nodeID, let inner):
      await runInSubGraph(nodeID, inner)

    case .pilotComposite(let nodeID):
      await pilotComposite(nodeID)

    case .armComposite(let nodeID):
      armComposite(nodeID)

    case .refreshUsage:
      await refreshUsage()
    }

    // Guarded re-fires need an `until` predicate answered first, which means a
    // subprocess — so they're queued during the synchronous pass and settled here,
    // before anyone is told what the graph looks like.
    await drainPendingMessages()
    await drainPendingCycleReentries()
    broadcast()
  }

  // MARK: - Proactive composites

  /// Runs a command against a proactive node's sub-graph, then rolls the result up.
  ///
  /// The nested graph is orchestrated by a real `GraphStore` — the same type, the same
  /// rules — rather than a cut-down interpreter. docs/05 is explicit that a composite is
  /// "the orchestrator running a graph inside a graph"; a second implementation would be
  /// a second set of bugs about edge firing.
  private func runInSubGraph(_ nodeID: UUID, _ command: GraphCommand) async {
    guard let node = graph.nodes[id: nodeID], node.loopType == .proactive,
      let subGraph = node.subGraph
    else { return }

    // Built fresh per command rather than cached: the sub-graph lives on the parent
    // node, which is the persisted source of truth, so a long-lived child store would
    // just be a copy that can drift from it.
    let child = GraphStore(
      graph: subGraph,
      onEnsureSession: onEnsureSession,
      onTerminateSession: onTerminateSession,
      onEvaluatePredicate: onEvaluatePredicate,
      onDeliverMessage: onDeliverMessage,
      onCaptureScript: onCaptureScript)
    await child.handle(command)
    graph.nodes[id: nodeID]?.subGraph = await child.graph
    rollUpComposite(nodeID)
  }

  /// A composite's own state *is* its sub-graph's aggregate — the roll-up docs/05 asks
  /// for. When that aggregate reaches something terminal, the parent resolves for real,
  /// which is what lets a composite sit in an ordinary graph and hand off like any other
  /// node.
  private func rollUpComposite(_ nodeID: UUID) {
    guard let node = graph.nodes[id: nodeID], let subGraph = node.subGraph else { return }
    let rolled = subGraph.aggregateState
    guard graph.nodes[id: nodeID]?.state != rolled else { return }

    switch rolled {
    case .succeeded:
      resolveNode(nodeID, succeeded: true)
    case .failed, .stalled:
      resolveNode(nodeID, succeeded: false)
    case .idle, .running, .awaitingInput, .blocked, .stopped:
      graph.nodes[id: nodeID]?.state = rolled
    }
  }

  /// The dry run docs/08 wants to be the path of least resistance: run the sub-graph
  /// once, now, so its cost is visible before anything is armed against a live trigger.
  ///
  /// "Against a small slice" is realised by running the sub-graph exactly as it stands —
  /// one pass, one item's worth of work — rather than by sampling some input set
  /// graphcode doesn't have. The point being served is that a human sees a real result
  /// and a real cost before hundreds of agents can be spawned, and one pass does that.
  private func pilotComposite(_ nodeID: UUID) async {
    guard let node = graph.nodes[id: nodeID], node.loopType == .proactive,
      node.subGraph != nil
    else { return }
    graph.nodes[id: nodeID]?.pilotState = .piloting
    graph.nodes[id: nodeID]?.state = .running

    // Start every unattended loop inside the composite. That *is* the pilot: real
    // sessions, real output, real cost — just not wired to the recurring trigger yet.
    if let subGraph = graph.nodes[id: nodeID]?.subGraph {
      for child in subGraph.nodes where child.runsUnattended {
        ensureSession(child)
      }
    }
    graph.nodes[id: nodeID]?.pilotState = .piloted
    await refreshUsage()
  }

  /// Arming is refused unless the node has been piloted. This is the enforcement behind
  /// docs/08's "proactive node armed against a live trigger → dry-run-on-a-slice is the
  /// default first step in the creation flow, not a separate manual command".
  private func armComposite(_ nodeID: UUID) {
    guard let node = graph.nodes[id: nodeID], node.loopType == .proactive,
      node.pilotState.canArm
    else { return }
    graph.nodes[id: nodeID]?.pilotState = .armed
    graph.nodes[id: nodeID]?.state = .running
  }

  // MARK: - Usage

  /// Asks each node's backend what it has spent. Nodes whose backend reports nothing are
  /// left with `usage == nil` — "not reported" rather than zero, which is the difference
  /// between a cost panel a human can trust and one that quietly under-counts.
  private func refreshUsage() async {
    guard let onReadUsage else { return }
    for node in graph.nodes {
      guard let sample = await onReadUsage(node) else { continue }
      graph.nodes[id: node.id]?.usage = sample
    }
  }

  // MARK: - Deletion

  /// Removing a node also removes every edge touching it — a dangling edge whose
  /// endpoint no longer exists would render as a line to nowhere and, worse, keep its
  /// target blocked on a handoff that can never arrive. Downstream targets are
  /// re-evaluated afterwards for exactly that reason.
  private func deleteNode(_ nodeID: UUID) {
    guard let node = graph.nodes[id: nodeID] else { return }

    let downstream = Set(graph.edges.filter { $0.from == nodeID }.map(\.to))
    graph.edges.removeAll { $0.from == nodeID || $0.to == nodeID }
    graph.nodes.remove(id: nodeID)
    cancelGoalPoller(nodeID)
    for targetID in downstream {
      unblockIfStillIdle(targetID)
    }

    // The graph was the only handle on a detached session; dropping the node without
    // this would leave a `claude` running with nothing in the UI pointing at it.
    onTerminateSession?(node)
  }

  /// The stop/kill affordance from docs/05-orchestrator.md#monitoring-surface — "a
  /// proactive routine runs until you turn it off", so there has to be an off.
  ///
  /// Downstream edges fire as if the loop failed. Not because stopping *is* a failure,
  /// but because the alternative is every node waiting on this one sitting blocked
  /// forever with no way to proceed — the same reasoning as a stall.
  private func stopNode(_ nodeID: UUID) {
    guard let node = graph.nodes[id: nodeID], !node.isResolved else { return }
    graph.nodes[id: nodeID]?.state = .stopped
    cancelGoalPoller(nodeID)
    onTerminateSession?(node)
    fireOutgoingEdges(from: nodeID, sourceSucceeded: false)
  }

  private func deleteEdge(_ edgeID: UUID) {
    guard let edge = graph.edges[id: edgeID] else { return }
    graph.edges.remove(id: edgeID)
    unblockIfStillIdle(edge.to)
  }

  // MARK: - Resolution + automatic edge firing

  private func resolveNode(_ nodeID: UUID, succeeded: Bool) {
    guard graph.nodes[id: nodeID] != nil else { return }
    graph.nodes[id: nodeID]?.state = succeeded ? .succeeded : .failed
    cancelGoalPoller(nodeID)
    fireOutgoingEdges(from: nodeID, sourceSucceeded: succeeded)
  }

  /// The Phase 3 half of docs/07-roadmap.md's "automatic edge evaluation and firing":
  /// evaluates every eligible outgoing `.handoff` edge's `EdgeCondition` against how the
  /// source node resolved, firing the ones that match and unblocking their targets.
  ///
  /// "Eligible" is `mayFireAgain`, which is where cycles enter: an unguarded edge is
  /// eligible only while it has never fired (exactly the pre-Phase-5 behaviour), and a
  /// guarded one stays eligible until its bound is reached.
  private func fireOutgoingEdges(from nodeID: UUID, sourceSucceeded: Bool) {
    let outgoing = graph.edges.filter {
      $0.from == nodeID && $0.kind.isExecutable && $0.mayFireAgain
    }
    for edge in outgoing where edge.condition.isSatisfied(sourceSucceeded: sourceSucceeded) {
      switch edge.kind {
      case .message:
        // Delivery needs a live session and possibly a script run, both of which mean
        // awaiting — queued and settled in the same drain as guarded re-fires.
        pendingMessages.append(edge.id)
        continue
      case .spawn:
        graph.edges[id: edge.id]?.fireCount += 1
        if let targetProject = edge.spawnTargetProjectPath {
          spawnIntoProject(targetProject, templateID: edge.to)
        } else {
          spawnInstance(of: edge.to)
        }
        continue
      case .handoff:
        break
      }
      if edge.cycleGuard != nil, edge.fireCount > 0 {
        // A re-fire has to clear the `until` predicate first, which means a subprocess.
        // Deferred to `pendingCycleRefires` so this stays synchronous; `handle` drains
        // it before broadcasting.
        pendingCycleReentries.append(edge.id)
        continue
      }
      commitFiring(edge.id)
    }
  }

  /// `.spawn` instantiates rather than unblocks (docs/02-graph-of-loops.md): the target
  /// is a *template*, and firing produces a fresh running copy of it while leaving the
  /// template itself untouched for the next spawn.
  ///
  /// The copy deliberately carries no inbound/outbound edges. A spawned instance is a
  /// unit of work, not a new participant in the template's relationships — wiring its
  /// edges up too would make every spawn multiply the graph's structure rather than just
  /// its work.
  private func spawnInstance(of templateID: UUID) {
    guard let template = graph.nodes[id: templateID] else { return }
    let isComposite = template.loopType == .proactive
    let instance = LoopNode(
      title: Self.instanceTitle(for: template, existing: graph.nodes.map(\.title)),
      loopType: template.loopType,
      checkDescription: template.checkDescription,
      triggerPrompt: template.triggerPrompt,
      goal: template.goal,
      backend: template.backend,
      modelTier: template.modelTier,
      worktreeBinding: template.worktreeBinding,
      // `reIdentified()` rather than a plain copy: node ids are `zmx` session names, so
      // sharing them would have every instance driving the template's own terminals.
      subGraph: template.subGraph?.reIdentified(),
      // A spawned composite is one live run, not a routine awaiting a schedule. The
      // pilot gate exists to stop a human arming a recurring trigger they've never
      // tried; something the graph deliberately instantiated has already cleared that
      // bar, and leaving it `.notPiloted` would spawn a composite that can't run.
      pilotState: isComposite ? .armed : .notPiloted,
      state: template.loopType == .goalBased || isComposite ? .running : .idle)
    graph.nodes.append(instance)

    if instance.runsUnattended { ensureSession(instance) }
    if instance.loopType == .goalBased { armGoalPoller(for: instance) }
    // A composite's work is its sub-graph's, so instantiating one has to start what's
    // inside it — otherwise the spawn produces a node that merely looks busy.
    if let subGraph = instance.subGraph {
      for child in subGraph.nodes where child.runsUnattended {
        ensureSession(child)
      }
    }
  }

  /// The cross-graph half of `.spawn` — the mechanism the global Orchestrator Graph uses
  /// to dispatch work into whichever project it concerns
  /// (docs/02-graph-of-loops.md#the-orchestrator-graph--global-vs-project-scope).
  ///
  /// The template stays here; only a draft of it travels. Sending a `NodeDraft` rather
  /// than a `LoopNode` matters: the receiving graph mints its own id and applies its own
  /// validation, so a spawn can't smuggle in a node the target graph would have refused
  /// to create itself.
  private func spawnIntoProject(_ projectPath: String, templateID: UUID) {
    guard let template = graph.nodes[id: templateID], let onSpawnIntoProject else { return }
    onSpawnIntoProject(
      projectPath,
      NodeDraft(
        title: template.title,
        loopType: template.loopType,
        checkDescription: template.checkDescription,
        triggerPrompt: template.triggerPrompt,
        goal: template.goal,
        backend: template.backend,
        modelTier: template.modelTier,
        worktree: template.worktreeBinding,
        // The routine travels with the draft; without it the receiving project would
        // get an empty composite that looks right and does nothing.
        subGraph: template.subGraph))
  }

  /// "Triage #2", "Triage #3" — a spawned instance needs to be tellable apart from its
  /// template at a glance in the sidebar, which is the only place many of them will
  /// ever be seen.
  static func instanceTitle(for template: LoopNode, existing: [String]) -> String {
    var index = 2
    while existing.contains("\(template.title) #\(index)") { index += 1 }
    return "\(template.title) #\(index)"
  }

  private func commitFiring(_ edgeID: UUID) {
    guard let edge = graph.edges[id: edgeID] else { return }
    graph.edges[id: edgeID]?.fireCount += 1
    if edge.cycleGuard != nil {
      reenterCycle(through: edge)
    } else {
      unblockIfStillIdle(edge.to)
    }
  }

  /// Firing a guarded edge into an already-resolved target is what starts the cycle's
  /// next pass. Resetting only that target isn't enough: every node *on the cycle* has
  /// already resolved and every edge between them has already fired, so without clearing
  /// those the second pass would stall one hop in.
  ///
  /// The cycle is computed rather than declared — the nodes reachable forward from the
  /// target that can also reach back to this edge's source. The guarded edge's own
  /// `fireCount` is deliberately *not* reset; it's the thing enforcing the bound.
  private func reenterCycle(through edge: LoopEdge) {
    let members = cycleMembers(from: edge.to, backTo: edge.from)
    for nodeID in members {
      graph.nodes[id: nodeID]?.state = .idle
      cancelGoalPoller(nodeID)
    }
    for other in graph.edges where other.id != edge.id {
      guard members.contains(other.from), members.contains(other.to) else { continue }
      graph.edges[id: other.id]?.fireCount = 0
    }
    for nodeID in members {
      unblockIfStillIdle(nodeID)
    }
    // Relaunch whatever the pass needs running again. `ZmxSessionLauncher` leaves a live
    // session alone, so this only revives loops whose session actually ended.
    for nodeID in members {
      guard let node = graph.nodes[id: nodeID] else { continue }
      if node.loopType == .goalBased { armGoalPoller(for: node) }
      if node.runsUnattended { ensureSession(node) }
    }
  }

  /// Nodes on the cycle closed by an edge `from → start`: reachable forward from `start`
  /// and able to reach `from` again, following executable edges only.
  private func cycleMembers(from start: UUID, backTo target: UUID) -> Set<UUID> {
    var forward: Set<UUID> = []
    var stack = [start]
    while let current = stack.popLast() {
      guard forward.insert(current).inserted else { continue }
      for edge in graph.edges where edge.from == current && edge.kind.blocksTarget {
        stack.append(edge.to)
      }
    }

    var backward: Set<UUID> = []
    stack = [target]
    while let current = stack.popLast() {
      guard backward.insert(current).inserted else { continue }
      for edge in graph.edges where edge.to == current && edge.kind.blocksTarget {
        stack.append(edge.from)
      }
    }

    var members = forward.intersection(backward)
    // Both endpoints belong to the cycle by construction, even in the degenerate case
    // where the graph has no other path between them.
    members.insert(start)
    members.insert(target)
    return members
  }

  /// Delivers the `.message` edges queued during the synchronous pass.
  ///
  /// An edge is marked fired only when the text actually landed. A message that couldn't
  /// be delivered is recorded in `undeliveredMessages` and left unfired, so it isn't
  /// quietly counted as having been sent — the difference matters when the whole point
  /// of the edge is that a peer was told something.
  private func drainPendingMessages() async {
    while !pendingMessages.isEmpty {
      let edgeID = pendingMessages.removeFirst()
      guard let edge = graph.edges[id: edgeID],
        let source = graph.nodes[id: edge.from],
        let target = graph.nodes[id: edge.to]
      else { continue }

      if let refusal = MessageBus.deliverability(to: target) {
        undeliveredMessages.append((edgeID, refusal))
        continue
      }
      guard
        let text = await MessageBus.messageText(
          for: edge, from: source, runScript: onCaptureScript)
      else {
        undeliveredMessages.append((edgeID, .emptyMessage))
        continue
      }
      guard let onDeliverMessage, await onDeliverMessage(target, text) else {
        undeliveredMessages.append((edgeID, .transportFailed))
        continue
      }
      graph.edges[id: edgeID]?.fireCount += 1
    }
  }

  /// Resolves the deferred re-fires from `fireOutgoingEdges`, asking each guard's
  /// `until` predicate whether the cycle should stop. A guard with no predicate is
  /// bounded by count alone and re-fires immediately.
  private func drainPendingCycleReentries() async {
    while !pendingCycleReentries.isEmpty {
      let edgeID = pendingCycleReentries.removeFirst()
      guard let edge = graph.edges[id: edgeID], edge.mayFireAgain else { continue }

      if let until = edge.cycleGuard?.effectiveUntil, let onEvaluatePredicate {
        let workingDirectory = graph.nodes[id: edge.from]?.worktreeBinding?.worktreePath
        let satisfied = await onEvaluatePredicate(
          ShellPredicate(command: until, workingDirectory: workingDirectory))
        // The condition holds, so the loop is done — stop without another pass.
        if satisfied { continue }
      }
      guard graph.edges[id: edgeID] != nil else { continue }
      commitFiring(edgeID)
    }
  }

  private func unblockIfStillIdle(_ nodeID: UUID) {
    guard graph.nodes[id: nodeID]?.state == .idle || graph.nodes[id: nodeID]?.state == .blocked
    else { return }
    let stillBlocked = graph.edges.contains {
      $0.to == nodeID && $0.kind.blocksTarget && !$0.fired
    }
    graph.nodes[id: nodeID]?.state = stillBlocked ? .blocked : .idle
  }

  // MARK: - Goal-based stop-condition polling

  /// docs/05-orchestrator.md#responsibilities item 4: evaluate a goal's stop condition
  /// periodically, *without* gating every turn. Only a node with a machine predicate
  /// gets a poller — a goal stated only in prose resolves when its session exits, the
  /// same way every other loop does.
  ///
  /// This is scheduling, which `GraphStore` otherwise avoids, and the distinction is
  /// worth being precise about: the earlier timers this store dropped *drove the work*
  /// headlessly, leaving nothing to attach to. This one only asks an outside question
  /// about work that is running in a perfectly ordinary session the whole time.
  private func armGoalPoller(for node: LoopNode) {
    guard let goal = node.goal else { return }
    // Two independent reasons to poll: a predicate to evaluate, or a stall bound to
    // enforce. A goal stated only in prose still deserves "this should have finished by
    // now" if its author gave it a bound.
    let hasPredicate = goal.effectivePredicate != nil && onEvaluatePredicate != nil
    guard hasPredicate || goal.stallAfterSeconds != nil else { return }
    goalPollers[node.id]?.cancel()
    let nodeID = node.id
    let interval = max(1, goal.pollIntervalSeconds)
    goalPollers[nodeID] = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(interval))
        guard !Task.isCancelled else { return }
        await self?.evaluateGoal(nodeID)
      }
    }
  }

  private func cancelGoalPoller(_ nodeID: UUID) {
    goalPollers.removeValue(forKey: nodeID)?.cancel()
  }

  /// One poll. Called on the timer in production and directly from tests, so the
  /// resolution logic can be exercised without anything sleeping.
  ///
  /// Order matters: the stall bound is checked *before* the predicate, so a loop that
  /// has blown its bound is reported as stalled rather than spending another predicate
  /// evaluation on it.
  public func evaluateGoal(_ nodeID: UUID, now: Date = Date()) async {
    guard let node = graph.nodes[id: nodeID], node.loopType == .goalBased, !node.isResolved,
      let goal = node.goal
    else {
      cancelGoalPoller(nodeID)
      return
    }

    if let stallAfter = goal.stallAfterSeconds,
      now.timeIntervalSince(node.createdAt) >= stallAfter
    {
      markStalled(nodeID)
      broadcast()
      return
    }

    // No machine predicate means polling has nothing to ask. Such a node resolves only
    // when its session exits — checked here, not just where the poller is armed, so an
    // evaluator can never resolve a goal whose author never gave it a testable one.
    guard let predicate = goal.effectivePredicate else { return }
    guard let onEvaluatePredicate,
      await onEvaluatePredicate(
        ShellPredicate(
          command: predicate, workingDirectory: node.worktreeBinding?.worktreePath))
    else { return }
    // Re-check: an await means the graph could have moved under us (the node deleted,
    // or its session exited and resolved it) while the predicate was running.
    guard let current = graph.nodes[id: nodeID], !current.isResolved else { return }
    resolveNode(nodeID, succeeded: true)
    broadcast()
  }

  /// A stalled loop is terminal, and its downstream edges fire as if it failed. Leaving
  /// them unfired would be tidier in theory but deadlocks the rest of the graph in
  /// practice — every node waiting on a stalled one would sit blocked forever with no
  /// way to proceed, which is worse than telling them the upstream didn't work out.
  private func markStalled(_ nodeID: UUID) {
    graph.nodes[id: nodeID]?.state = .stalled
    cancelGoalPoller(nodeID)
    fireOutgoingEdges(from: nodeID, sourceSucceeded: false)
  }

  // MARK: - Time-based session liveness

  /// Makes sure every unattended node in this graph — time-based and goal-based — has
  /// its session running, and re-arms goal polling. Called when a persisted graph is
  /// first loaded (`ProjectRegistry.store(forProjectPath:)`), which is what gets loops
  /// going again after a reboot or a daemon restart: the session itself is long-lived,
  /// but nothing outside it would otherwise recreate it once it's gone.
  ///
  /// Turn-based nodes are deliberately excluded — a human opening one is what starts it.
  /// So is a goal that has already resolved: re-pursuing a met goal would restart work
  /// the graph has already recorded as finished. (A time-based node gets no such
  /// exclusion, matching the behaviour it had before goals existed — its whole premise
  /// is that it keeps running.)
  ///
  /// Safe to call repeatedly, but only because `ZmxSessionLauncher` checks for an
  /// existing session first — `zmx run` itself is *not* idempotent, and re-running it
  /// against a live session types the prompt in a second time.
  public func ensureUnattendedSessions() {
    for node in graph.nodes where node.runsUnattended {
      if node.loopType == .goalBased {
        guard !node.isResolved else { continue }
        armGoalPoller(for: node)
      }
      ensureSession(node)
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
