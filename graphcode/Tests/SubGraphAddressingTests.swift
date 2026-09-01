import ComposableArchitecture
import Foundation
import IdentifiedCollections
import Testing

@testable import GraphcodeKit

/// Addressing a sub-graph child by its own id — the fix for issue #217 item 15.
///
/// A piloted child is briefed to `node memo <project> <its-own-id>` — ids are unique
/// across the whole tree, so a caller has no reason to know how deep its target sits.
/// Resolving that id against the top-level nodes only answered "no loop <id> in this
/// graph" for a loop that plainly existed, which locked composite children out of
/// memo, refine, send, delete, and edges from the CLI entirely.
@Suite
struct SubGraphAddressingTests {
  private func storeWithComposite(
    subNodes: [LoopNode] = [],
    onCheckPredicate: (@Sendable (ShellPredicate) async -> PredicateOutcome?)? = nil,
    onAppendMemory: (@Sendable (UUID, String) -> Void)? = nil,
    onRefinePlaybook: (@Sendable (UUID, String) -> Bool)? = nil,
    onDeliverMessage: (@Sendable (LoopNode, String, String?) async -> Bool)? = nil,
    onAnnounceError: (@Sendable (String) -> Void)? = nil
  ) -> (store: GraphStore, compositeID: UUID) {
    let composite = LoopNode(
      title: "Triage inbox", loopType: .composite,
      subGraph: LoopGraph(
        project: ProjectRef(path: "sub", name: "sub"),
        nodes: IdentifiedArray(uniqueElements: subNodes)))
    let store = GraphStore(
      graph: LoopGraph(
        project: ProjectRef(path: "/tmp/p", name: "p"), nodes: [composite]),
      onCheckPredicate: onCheckPredicate,
      onDeliverMessage: onDeliverMessage,
      onAppendMemory: onAppendMemory,
      onRefinePlaybook: onRefinePlaybook,
      onAnnounceError: onAnnounceError)
    return (store, composite.id)
  }

  @Test
  func aChildLoopCanMemoItselfByItsOwnId() async {
    let memories = LockIsolated<[UUID: [String]]>([:])
    let worker = LoopNode(title: "Worker", loopType: .turnBased, checkDescription: "?")
    let (store, _) = storeWithComposite(
      subNodes: [worker],
      onAppendMemory: { id, text in
        memories.withValue { $0[id, default: []].append(text) }
      })

    await store.handle(.memoNode(worker.id, text: "classified 12 items", from: nil))

    #expect(memories.value[worker.id]?.contains("note: classified 12 items") == true)
  }

  @Test
  func aChildLoopCanRefineItselfByItsOwnId() async {
    let refined = LockIsolated<[UUID: String]>([:])
    let worker = LoopNode(title: "Worker", loopType: .turnBased, checkDescription: "?")
    let (store, _) = storeWithComposite(
      subNodes: [worker],
      onRefinePlaybook: { id, text in
        refined.withValue { $0[id] = text }
        return true
      })

    await store.handle(.refineNode(worker.id, text: "check the queue first", from: nil))

    #expect(refined.value[worker.id] == "check the queue first")
  }

  @Test
  func aMessageAddressedToAChildLoopReachesItsTransport() async {
    let delivered = LockIsolated<[UUID]>([])
    let worker = LoopNode(title: "Worker", loopType: .turnBased, checkDescription: "?")
    let (store, _) = storeWithComposite(
      subNodes: [worker],
      onDeliverMessage: { node, _, _ in
        delivered.withValue { $0.append(node.id) }
        return true
      })

    await store.handle(
      .messageNode(worker.id, text: "prioritize the inbox", from: nil, followUp: nil))

    #expect(delivered.value == [worker.id])
  }

  @Test
  func aChildLoopCanBeDeletedByItsOwnId() async {
    let worker = LoopNode(title: "Worker", loopType: .turnBased, checkDescription: "?")
    let (store, compositeID) = storeWithComposite(subNodes: [worker])

    await store.handle(.deleteNode(worker.id))

    #expect(await store.graph.nodes[id: compositeID]?.subGraph?.nodes.isEmpty == true)
  }

  @Test
  func anEdgeBetweenChildLoopsCanBeCreatedFromOutsideTheComposite() async {
    let classify = LoopNode(title: "Classify", loopType: .turnBased, checkDescription: "?")
    let draft = LoopNode(title: "Draft reply", loopType: .turnBased, checkDescription: "?")
    let (store, compositeID) = storeWithComposite(subNodes: [classify, draft])

    await store.handle(.createEdge(from: classify.id, to: draft.id, spec: EdgeSpec()))

    let sub = await store.graph.nodes[id: compositeID]?.subGraph
    #expect(sub?.edges.count == 1)
    // Edge semantics apply inside a composite exactly as outside it.
    #expect(sub?.nodes[id: draft.id]?.state == .blocked)
  }

  @Test
  func aNestedChildIsReachedThroughBothLevelsByItsOwnId() async throws {
    // A composite inside a composite: the deep loop's id still needs no path form —
    // each level's routing descends one hop, the way `runInSubGraph` already did for
    // wrapped commands.
    let memories = LockIsolated<[UUID: [String]]>([:])
    let (store, outerID) = storeWithComposite(
      onAppendMemory: { id, text in
        memories.withValue { $0[id, default: []].append(text) }
      })
    await store.handle(
      .subGraphCommand(
        nodeID: outerID, command: .createNode(NodeDraft(title: "Inner", loopType: .composite))))
    let innerID = try #require(await store.graph.nodes[id: outerID]?.subGraph?.nodes.first?.id)
    await store.handle(
      .subGraphCommand(
        nodeID: innerID,
        command: .createNode(
          NodeDraft(
            title: "Deep", loopType: .turnBased, checkDescription: "?",
            firstInstruction: "Work"))))
    let deepID = try #require(
      await store.graph.nodes[id: outerID]?.subGraph?.nodes[id: innerID]?.subGraph?.nodes.first?.id)

    await store.handle(.memoNode(deepID, text: "made it down", from: nil))

    #expect(memories.value[deepID]?.contains("note: made it down") == true)
  }

  @Test
  func aMemoForAnIdThatExistsNowhereIsStillRefusedByName() async {
    // Routing must not swallow the plain failure: an id naming no loop anywhere gets
    // the message the caller expects.
    let errors = LockIsolated<[String]>([])
    let (store, _) = storeWithComposite(
      onAnnounceError: { message in errors.withValue { $0.append(message) } })
    let missing = UUID()

    await store.handle(.memoNode(missing, text: "gone", from: nil))

    #expect(errors.value == ["memo not recorded: no loop \(missing) in this graph"])
  }

  @Test
  func aRefusalInsideASubGraphIsAnnouncedRatherThanSwallowed() async {
    // The child store owns no connections, so before errors were forwarded up, a
    // routed command that was refused — empty note, over-long playbook, staged
    // message — was said to nobody and the CLI timed out on it.
    let errors = LockIsolated<[String]>([])
    let worker = LoopNode(title: "Worker", loopType: .turnBased, checkDescription: "?")
    let (store, _) = storeWithComposite(
      subNodes: [worker],
      onAnnounceError: { message in errors.withValue { $0.append(message) } })

    await store.handle(.memoNode(worker.id, text: "   ", from: nil))

    #expect(errors.value == ["memo not recorded: empty note"])
  }

  @Test
  func anUpdateRoutesIntoAChildLoop() async {
    let worker = LoopNode(title: "Worker", loopType: .turnBased, checkDescription: "?")
    let (store, compositeID) = storeWithComposite(subNodes: [worker])

    await store.handle(
      .updateNode(worker.id, update: NodeUpdate(checkDescription: "reviewed?")))

    #expect(
      await store.graph.nodes[id: compositeID]?.subGraph?.nodes[id: worker.id]?
        .checkDescription == "reviewed?")
  }

  @Test
  func aChildLoopCanBeStoppedByItsOwnId() async {
    let worker = LoopNode(title: "Worker", loopType: .turnBased, checkDescription: "?")
    let (store, compositeID) = storeWithComposite(subNodes: [worker])

    await store.handle(.stopNode(worker.id))

    #expect(
      await store.graph.nodes[id: compositeID]?.subGraph?.nodes[id: worker.id]?.state
        == .stopped)
  }

  @Test
  func aChildLoopCanBePromotedByItsOwnId() async {
    let seedling = LoopNode(title: "Seedling", loopType: .sketch)
    let (store, compositeID) = storeWithComposite(subNodes: [seedling])

    await store.handle(
      .promoteNode(
        seedling.id,
        promotion: .goal(GoalSpec(summary: "done means the changelog is written")),
        promotedBy: nil))

    let promoted = await store.graph.nodes[id: compositeID]?.subGraph?.nodes[id: seedling.id]
    #expect(promoted?.loopType == .goalBased)
    #expect(promoted?.state == .running)
  }

  @Test
  func anEdgeFromATopLevelLoopToAChildLoopIsRefusedAsASpan() async throws {
    // No edge may span two graphs. Refused out loud — the caller is waiting for an
    // answer, and silence reads as a timeout, not a refusal.
    let worker = LoopNode(title: "Worker", loopType: .turnBased, checkDescription: "?")
    let errors = LockIsolated<[String]>([])
    let (store, _) = storeWithComposite(
      subNodes: [worker],
      onAnnounceError: { message in errors.withValue { $0.append(message) } })
    await store.handle(.createNode(NodeDraft(title: "Outside", loopType: .turnBased)))
    let outsideID = try #require(await store.graph.nodes.last?.id)

    await store.handle(.createEdge(from: outsideID, to: worker.id, spec: EdgeSpec()))

    #expect(errors.value.count == 1)
    #expect(errors.value.first?.hasPrefix("edge refused: an edge may not span two graphs") == true)
  }

  @Test
  func anEdgeToAnUnknownLoopIsRefusedByName() async throws {
    let outside = LoopNode(title: "Outside", loopType: .turnBased, checkDescription: "?")
    let errors = LockIsolated<[String]>([])
    let (store, _) = storeWithComposite(
      onAnnounceError: { message in errors.withValue { $0.append(message) } })
    await store.handle(.createNode(NodeDraft(title: "Outside", loopType: .turnBased)))
    let outsideID = try #require(await store.graph.nodes.last?.id)
    let missing = UUID()

    await store.handle(.createEdge(from: outsideID, to: missing, spec: EdgeSpec()))

    #expect(errors.value == ["edge refused: no loop \(missing) in this graph"])
  }

  // MARK: - Recurrence for sub-graph loops

  // A per-command child store cannot hold a timer — one armed there would die with the
  // store, which is how a `--poll` change on a child was silently inert. Recurrence is
  // now armed on the project store and ticks into the sub-graph by descent.

  @Test
  func aPilotedChildsGoalIsPolledFromTheProjectStore() async throws {
    let polls = LockIsolated(0)
    let worker = LoopNode(
      title: "Worker", loopType: .goalBased,
      goal: GoalSpec(summary: "ship it", predicate: "true", pollIntervalSeconds: 1))
    let (store, compositeID) = storeWithComposite(
      subNodes: [worker],
      onCheckPredicate: { _ in
        polls.withValue { $0 += 1 }
        return PredicateOutcome(passed: false)
      })

    await store.handle(.pilotComposite(compositeID))
    #expect(await store.graph.nodes[id: compositeID]?.pilotState == .piloted)
    try await Task.sleep(for: .seconds(1.6))

    #expect(polls.value >= 1)
  }

  @Test
  func anUpdateToAChildsPollIntervalReachesTheProjectStoresPoller() async throws {
    // The regression: the re-arm used to land in the ephemeral child store and die
    // with it, so a `--poll` change was silently ignored. The poller here was armed by
    // the pilot at the default 60s; the routed update must replace it with a 1s one.
    let polls = LockIsolated(0)
    let worker = LoopNode(
      title: "Worker", loopType: .goalBased,
      goal: GoalSpec(summary: "ship it", predicate: "true", pollIntervalSeconds: 60))
    let (store, compositeID) = storeWithComposite(
      subNodes: [worker],
      onCheckPredicate: { _ in
        polls.withValue { $0 += 1 }
        return PredicateOutcome(passed: false)
      })
    await store.handle(.pilotComposite(compositeID))

    await store.handle(
      .updateNode(worker.id, update: NodeUpdate(pollIntervalSeconds: 1)))
    try await Task.sleep(for: .seconds(1.6))

    #expect(polls.value >= 1)
  }

  @Test
  func anUnpilotedChildsGoalIsNeverPolled() async throws {
    // A template's goal resolving would mark work done that never ran, so recurrence
    // handed up from a child store is gated on its composite having been piloted.
    let polls = LockIsolated(0)
    let worker = LoopNode(
      title: "Worker", loopType: .goalBased,
      goal: GoalSpec(summary: "ship it", predicate: "true", pollIntervalSeconds: 1))
    let (store, _) = storeWithComposite(
      subNodes: [worker],
      onCheckPredicate: { _ in
        polls.withValue { $0 += 1 }
        return PredicateOutcome(passed: false)
      })

    await store.handle(
      .updateNode(worker.id, update: NodeUpdate(pollIntervalSeconds: 1)))
    try await Task.sleep(for: .seconds(1.6))

    #expect(polls.value == 0)
  }
}
