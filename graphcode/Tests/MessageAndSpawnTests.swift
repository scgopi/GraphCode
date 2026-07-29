import ComposableArchitecture
import Foundation
import GraphcodeKit
import Testing

/// The two edge kinds Phase 6 brings to life: `.message` (deliver into a live peer) and
/// `.spawn` (instantiate a template). See docs/02-graph-of-loops.md#edgekind.
@Suite
struct MessageAndSpawnTests {
  private struct Delivery: Equatable {
    let nodeTitle: String
    let text: String
  }

  /// Source → target with a `.message` edge, target left in whatever state is under test.
  private func messagePair(
    targetState: LoopState,
    targetBackend: CLISessionBackendKind = .claudeCode,
    transform: PayloadTransform = .none,
    transportSucceeds: Bool = true,
    delivered: LockIsolated<[Delivery]>,
    captureScript: (@Sendable (ShellPredicate) async -> String?)? = nil
  ) async -> GraphStore {
    let source = LoopNode(title: "Implement", state: .running)
    let target = LoopNode(title: "Review", backend: targetBackend, state: targetState)
    let graph = LoopGraph(
      project: ProjectRef(path: "/tmp/msg", name: "msg"),
      nodes: [source, target],
      edges: [
        LoopEdge(from: source.id, to: target.id, kind: .message, payloadTransform: transform)
      ])
    return GraphStore(
      graph: graph,
      onDeliverMessage: { node, text in
        delivered.withValue { $0.append(Delivery(nodeTitle: node.title, text: text)) }
        return transportSucceeds
      },
      onCaptureScript: captureScript)
  }

  @Test
  func aMessageIsTypedIntoTheLivePeersSession() async {
    let delivered = LockIsolated<[Delivery]>([])
    let store = await messagePair(
      targetState: .running, transform: .template("early opinion?"), delivered: delivered)
    let sourceID = await store.graph.nodes[0].id

    await store.handle(.nodeCheckApproved(sourceID))

    #expect(delivered.value.count == 1)
    #expect(delivered.value[0].nodeTitle == "Review")
    #expect(delivered.value[0].text.contains("early opinion?"))
    // Marked fired only because it actually landed.
    #expect(await store.graph.edges[0].fired == true)
  }

  @Test
  func aMessageEdgeDoesNotUnblockOrResolveTheTarget() async {
    // It's a nudge to a running peer, not a hand-off — the target's own lifecycle is
    // untouched.
    let delivered = LockIsolated<[Delivery]>([])
    let store = await messagePair(targetState: .running, delivered: delivered)
    let sourceID = await store.graph.nodes[0].id

    await store.handle(.nodeCheckApproved(sourceID))

    #expect(await store.graph.nodes[1].state == .running)
  }

  @Test
  func aMessageIsNotDeliveredIntoANodeMidCheck() async {
    // docs/05: you wouldn't want two people typing into one terminal at once. A node
    // awaiting input is exactly that, so the orchestrator holds the message back.
    let delivered = LockIsolated<[Delivery]>([])
    let store = await messagePair(targetState: .awaitingInput, delivered: delivered)
    let sourceID = await store.graph.nodes[0].id

    await store.handle(.nodeCheckApproved(sourceID))

    #expect(delivered.value.isEmpty)
    #expect(await store.graph.edges[0].fired == false)
    #expect(await store.undeliveredMessages.first?.reason == .targetBusyWithACheck)
  }

  @Test
  func aMessageToAFinishedNodeIsNotDelivered() async {
    // There's no session left to type into. Silently "succeeding" here would be the
    // worst outcome: the graph would claim a peer was told something it never heard.
    let delivered = LockIsolated<[Delivery]>([])
    let store = await messagePair(targetState: .succeeded, delivered: delivered)
    let sourceID = await store.graph.nodes[0].id

    await store.handle(.nodeCheckApproved(sourceID))

    #expect(delivered.value.isEmpty)
    #expect(await store.undeliveredMessages.first?.reason == .targetNotLive)
  }

  @Test
  func everyBackendCanCurrentlyBeAMessageTarget() {
    // docs/04-cli-backends.md says a backend that can't be interrupted mid-session can
    // never be the `to` side of a `.message` edge, and `GraphStore` still refuses one with
    // `.backendCannotAcceptInput`.
    //
    // That refusal is currently **unreachable**, because all three backends are TUIs in a
    // PTY that `zmx send` can type into — Codex included, since it was spiked (issue #1).
    // This asserts the state of the world that makes it unreachable, so the day a backend
    // arrives that can't take input, this test fails and points at the rule that needs
    // exercising again.
    for backend in CLISessionBackendKind.allCases {
      #expect(backend.capabilities.supportsMidSessionInput)
    }
  }

  @Test
  func aFailedTransportLeavesTheEdgeUnfired() async {
    let delivered = LockIsolated<[Delivery]>([])
    let store = await messagePair(
      targetState: .running, transportSucceeds: false, delivered: delivered)
    let sourceID = await store.graph.nodes[0].id

    await store.handle(.nodeCheckApproved(sourceID))

    #expect(delivered.value.count == 1)
    #expect(await store.graph.edges[0].fired == false)
    #expect(await store.undeliveredMessages.first?.reason == .transportFailed)
  }

  @Test
  func aScriptTransformProducesTheMessageBody() async {
    // docs/08: a script is cheaper than reasoning through the steps every time.
    let delivered = LockIsolated<[Delivery]>([])
    let store = await messagePair(
      targetState: .running,
      transform: .script("git diff --stat"),
      delivered: delivered,
      captureScript: { _ in "3 files changed" })
    let sourceID = await store.graph.nodes[0].id

    await store.handle(.nodeCheckApproved(sourceID))

    #expect(delivered.value.first?.text.contains("3 files changed") == true)
  }

  @Test
  func aScriptThatProducesNothingSendsNothing() async {
    let delivered = LockIsolated<[Delivery]>([])
    let store = await messagePair(
      targetState: .running,
      transform: .script("true"),
      delivered: delivered,
      captureScript: { _ in nil })
    let sourceID = await store.graph.nodes[0].id

    await store.handle(.nodeCheckApproved(sourceID))

    #expect(delivered.value.isEmpty)
    #expect(await store.undeliveredMessages.first?.reason == .emptyMessage)
  }

  @Test
  func spawningTwiceProducesTwoDistinctlyNamedInstances() async {
    let store = GraphStore()
    await store.handle(
      .createNode(NodeDraft(title: "Triage", loopType: .turnBased, checkDescription: "?")))
    await store.handle(
      .createNode(NodeDraft(title: "Worker", loopType: .turnBased, checkDescription: "?")))
    let nodes = await store.graph.nodes
    await store.handle(
      .createEdge(
        from: nodes[0].id, to: nodes[1].id,
        spec: EdgeSpec(kind: .spawn, cycleGuard: CycleGuard(maxIterations: 5))))

    await store.handle(.nodeCheckApproved(nodes[0].id))
    await store.handle(.nodeCheckApproved(nodes[0].id))

    let titles = await store.graph.nodes.map(\.title)
    #expect(titles == ["Triage", "Worker", "Worker #2", "Worker #3"])
  }

  @Test
  func aSpawnedInstanceInheritsItsTemplatesConfiguration() async {
    // The template is the specification; an instance that dropped its backend, tier, or
    // worktree would quietly run different work than the one that was designed.
    let worktree = WorktreeRef(
      id: "wt", repositoryPath: "/repo", worktreePath: "/repo-wt", branch: "wt")
    let trigger = LoopNode(title: "Trigger", state: .idle)
    let template = LoopNode(
      title: "Worker", loopType: .timeBased, triggerPrompt: "/loop 1h Check",
      modelTier: .capable, worktreeBinding: worktree)
    let graph = LoopGraph(
      project: ProjectRef(path: "/tmp/spawn", name: "spawn"),
      nodes: [trigger, template],
      edges: [LoopEdge(from: trigger.id, to: template.id, kind: .spawn)])
    let started = LockIsolated<[LoopNode]>([])
    let store = GraphStore(
      graph: graph, onEnsureSession: { node, _ in started.withValue { $0.append(node) } })

    await store.handle(.nodeCheckApproved(trigger.id))

    let instance = try? #require(await store.graph.nodes.last)
    #expect(instance?.title == "Worker #2")
    #expect(instance?.modelTier == .capable)
    #expect(instance?.worktreeBinding == worktree)
    #expect(instance?.triggerPrompt == "/loop 1h Check")
    // An unattended instance starts working immediately — spawning it and not running it
    // would just litter the graph.
    #expect(started.value.map(\.title) == ["Worker #2"])
  }

  @Test
  func aSpawnEdgeNeverBlocksItsTemplate() async {
    // A template is not waiting on anything; leaving it `.blocked` would make it
    // unopenable and stop it ever being spawned from again.
    let store = GraphStore()
    await store.handle(
      .createNode(NodeDraft(title: "Trigger", loopType: .turnBased, checkDescription: "?")))
    await store.handle(
      .createNode(NodeDraft(title: "Worker", loopType: .turnBased, checkDescription: "?")))
    let nodes = await store.graph.nodes

    await store.handle(
      .createEdge(from: nodes[0].id, to: nodes[1].id, spec: EdgeSpec(kind: .spawn)))

    #expect(await store.graph.nodes[1].state == .idle)
  }
}
