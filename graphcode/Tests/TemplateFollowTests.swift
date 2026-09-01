import ComposableArchitecture
import Foundation
import GraphcodeKit
import Testing

@testable import GraphcodeKit

/// Follow vs snapshot — the half of the template design that lives in the daemon
/// (PROMPT_TEMPLATES.md § Follow vs snapshot).
///
/// **Timed and composite loops follow their template** and pick up edits on the
/// next run; **Main, goal and turn loops snapshot at creation** and a running
/// session can never have its brief swapped underneath it. A deleted template is
/// a warning on the card, not a failure: the loop keeps its last-known snapshot.
@Suite
struct TemplateFollowTests {
  /// Injected reads against a scratch directory; nothing here touches the real
  /// `~/.graphcode`.
  private let storage: TemplateStorage
  private let home: URL
  private let projectPath: String

  init() {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("template-follow-tests-\(UUID().uuidString)", isDirectory: true)
    home = root.appendingPathComponent("home", isDirectory: true)
    projectPath = root.appendingPathComponent("repo", isDirectory: true).path
    try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(
      at: URL(fileURLWithPath: projectPath, isDirectory: true), withIntermediateDirectories: true)
    storage = TemplateStorage(
      homeDirectory: home,
      projectDirectory: { path in
        URL(fileURLWithPath: path, isDirectory: true)
          .appendingPathComponent(".graphcode", isDirectory: true)
          .appendingPathComponent("templates", isDirectory: true)
      })
  }

  private func saveNightly(_ template: PromptTemplate) throws {
    try storage.save(template, to: .home, projectPath: projectPath)
  }

  private func makeStore(
    resolve: (@Sendable (UUID, String?) -> PromptTemplate?)? = nil
  ) -> GraphStore {
    GraphStore(
      onEnsureSession: { _, _ in },
      onResolveTemplate:
        resolve
        ?? { id, _ in self.storage.template(withID: id, projectPath: self.projectPath) })
  }

  @Test
  func aTimedLoopPicksUpEditOnItsNextRun() async throws {
    let id = UUID()
    try saveNightly(
      PromptTemplate(
        id: id, name: "Nightly dependency review",
        body: "Check for updates worth taking and say what would break.",
        shape: .timeBased, settings: TemplateSettings(cadence: "daily")))
    let started = LockIsolated<[LoopNode]>([])
    let store = GraphStore(
      onEnsureSession: { node, _ in started.withValue { $0.append(node) } },
      onResolveTemplate: { templateID, _ in
        self.storage.template(withID: templateID, projectPath: self.projectPath)
      })
    await store.handle(
      .createNode(
        NodeDraft(
          title: "Nightly dependency review", loopType: .timeBased,
          triggerPrompt: "/loop daily Check for updates worth taking and say what would break.",
          templateFollow: TemplateFollow(id: id, name: "Nightly dependency review"))))
    let before = await store.graph
    #expect(before.nodes[0].templateFollow?.missing == false)

    // The template is edited — the *next run* is what picks it up.
    try saveNightly(
      PromptTemplate(
        id: id, name: "Nightly dependency review", body: "Check dependencies and triage.",
        shape: .timeBased, settings: TemplateSettings(cadence: "daily")))

    await store.ensureUnattendedSessions()
    let after = await store.graph
    #expect(after.nodes[0].triggerPrompt == "/loop daily Check dependencies and triage.")
    // The launch carried the refreshed brief, not the snapshot.
    #expect(started.value.last?.triggerPrompt == "/loop daily Check dependencies and triage.")
  }

  @Test
  func aGoalLoopSnapshotsAtCreationAndNeverFollows() async throws {
    let id = UUID()
    try saveNightly(
      PromptTemplate(id: id, name: "Nightly", body: "irrelevant", shape: .timeBased))
    let store = makeStore()
    await store.handle(
      .createNode(
        NodeDraft(
          title: "Green build", loopType: .goalBased,
          goal: GoalSpec(summary: "CI passes", predicate: "make test"),
          // A goal loop cannot follow, whatever the draft carried — makeNode
          // drops the follow for every type that snapshots.
          createdFromTemplateID: id, templateFollow: TemplateFollow(id: id, name: "Nightly"))))

    let graph = await store.graph
    #expect(graph.nodes[0].createdFromTemplateID == id)
    #expect(graph.nodes[0].templateFollow == nil)
  }

  @Test
  func aDeletedTemplateWarnsAndRunsItsSnapshot() async throws {
    let id = UUID()
    try saveNightly(
      PromptTemplate(
        id: id, name: "Nightly dependency review", body: "Check dependencies.",
        shape: .timeBased, settings: TemplateSettings(cadence: "daily")))
    let store = makeStore()
    await store.handle(
      .createNode(
        NodeDraft(
          title: "Nightly", loopType: .timeBased, triggerPrompt: "/loop daily Check dependencies.",
          templateFollow: TemplateFollow(id: id, name: "Nightly dependency review"))))

    // The file goes away — the next run keeps the snapshot and flips the warning.
    try FileManager.default.removeItem(
      at: storage.homeDirectory.appendingPathComponent("nightly-dependency-review.md"))
    await store.ensureUnattendedSessions()

    let graph = await store.graph
    #expect(graph.nodes[0].templateFollow?.missing == true)
    #expect(graph.nodes[0].triggerPrompt == "/loop daily Check dependencies.")
  }

  @Test
  func detachingConvertsTheLoopToASnapshotInPlace() async throws {
    let id = UUID()
    try saveNightly(
      PromptTemplate(
        id: id, name: "Nightly dependency review", body: "Check dependencies.",
        shape: .timeBased, settings: TemplateSettings(cadence: "daily")))
    let store = makeStore()
    await store.handle(
      .createNode(
        NodeDraft(
          title: "Nightly", loopType: .timeBased, triggerPrompt: "/loop daily Check dependencies.",
          templateFollow: TemplateFollow(id: id, name: "Nightly dependency review"))))
    let nodeID = await store.graph.nodes[0].id

    await store.handle(.detachTemplate(nodeID))
    let graph = await store.graph
    #expect(graph.nodes[0].templateFollow == nil)
    #expect(graph.nodes[0].triggerPrompt == "/loop daily Check dependencies.")
  }

  @Test
  func aCompositePilotReReadsTheTemplateItFollows() async throws {
    let id = UUID()
    let reviewerGraph = LoopGraph(
      project: ProjectRef(path: "review", name: "review"),
      nodes: [LoopNode(title: "Reviewer v1", loopType: .goalBased, goal: GoalSpec(summary: "Find"))]
    )
    try saveNightly(
      PromptTemplate(
        id: id, name: "Review, fix, verify", body: "Hand findings along.", shape: .composite,
        settings: TemplateSettings(graphJSON: TemplateSettings.graphJSON(for: reviewerGraph))))

    let store = makeStore()
    let stale = LoopGraph(
      project: ProjectRef(path: "stale", name: "stale"),
      nodes: [LoopNode(title: "Old child", loopType: .sketch)])
    await store.handle(
      .createNode(
        NodeDraft(
          title: "Review, fix, verify", loopType: .composite,
          triggerPrompt: "Intended schedule: daily at 09:00",
          subGraph: stale,
          templateFollow: TemplateFollow(id: id, name: "Review, fix, verify"))))
    let compositeID = await store.graph.nodes[0].id

    await store.handle(.pilotComposite(compositeID))
    let graph = await store.graph
    // The pilot is the composite's next run: the sub-graph the template now
    // carries replaced the stale one.
    #expect(graph.nodes[0].subGraph?.nodes.map(\.title) == ["Reviewer v1"])
    #expect(graph.nodes[0].templateFollow?.missing == false)
  }

  /// The pilot is a run boundary, not a rebuild. A template whose graph hasn't
  /// changed must leave the children exactly where they are: node ids are `zmx`
  /// session names, so re-identifying them orphans every session the last pass
  /// started and strands its memory under an id no card can reach.
  @Test
  func anUnchangedCompositeTemplateLeavesItsChildrenAlone() async throws {
    let id = UUID()
    let carried = LoopGraph(
      project: ProjectRef(path: "review", name: "review"),
      nodes: [LoopNode(title: "Reviewer", loopType: .goalBased, goal: GoalSpec(summary: "Find"))])
    try saveNightly(
      PromptTemplate(
        id: id, name: "Review, fix, verify", body: "Hand findings along.", shape: .composite,
        settings: TemplateSettings(graphJSON: TemplateSettings.graphJSON(for: carried))))

    let killed = LockIsolated<[UUID]>([])
    let store = GraphStore(
      onEnsureSession: { _, _ in },
      onTerminateSession: { node, _ in killed.withValue { $0.append(node.id) } },
      onResolveTemplate: { templateID, _ in
        self.storage.template(withID: templateID, projectPath: self.projectPath)
      })
    await store.handle(
      .createNode(
        NodeDraft(
          title: "Review, fix, verify", loopType: .composite,
          subGraph: carried,
          templateFollow: TemplateFollow(id: id, name: "Review, fix, verify"))))
    let compositeID = await store.graph.nodes[0].id
    let childrenBefore = await store.graph.nodes[0].subGraph?.nodes.map(\.id)

    await store.handle(.pilotComposite(compositeID))
    await store.handle(.pilotComposite(compositeID))

    let childrenAfter = await store.graph.nodes[0].subGraph?.nodes.map(\.id)
    #expect(childrenAfter == childrenBefore)
    #expect(killed.value.isEmpty)
  }

  /// And when the template's graph *has* changed, the outgoing children are torn
  /// down rather than left running against a graph that no longer holds them.
  @Test
  func aChangedCompositeTemplateTearsDownTheOldChildren() async throws {
    let id = UUID()
    let first = LoopGraph(
      project: ProjectRef(path: "review", name: "review"),
      nodes: [LoopNode(title: "Reviewer v1", loopType: .goalBased, goal: GoalSpec(summary: "Find"))]
    )
    try saveNightly(
      PromptTemplate(
        id: id, name: "Review, fix, verify", body: "Hand findings along.", shape: .composite,
        settings: TemplateSettings(graphJSON: TemplateSettings.graphJSON(for: first))))

    let killed = LockIsolated<[String]>([])
    let store = GraphStore(
      onEnsureSession: { _, _ in },
      onTerminateSession: { node, _ in killed.withValue { $0.append(node.title) } },
      onResolveTemplate: { templateID, _ in
        self.storage.template(withID: templateID, projectPath: self.projectPath)
      })
    let stale = LoopGraph(
      project: ProjectRef(path: "stale", name: "stale"),
      nodes: [LoopNode(title: "Old child", loopType: .sketch)])
    await store.handle(
      .createNode(
        NodeDraft(
          title: "Review, fix, verify", loopType: .composite, subGraph: stale,
          templateFollow: TemplateFollow(id: id, name: "Review, fix, verify"))))
    let compositeID = await store.graph.nodes[0].id

    await store.handle(.pilotComposite(compositeID))
    let graph = await store.graph
    #expect(graph.nodes[0].subGraph?.nodes.map(\.title) == ["Reviewer v1"])
    #expect(killed.value.contains("Old child"))
  }

  /// A composite template that carries no graph is unfinished, not missing: the file
  /// was found, so the card must not warn that it wasn't.
  @Test
  func aCompositeTemplateWithNoGraphIsNotReportedMissing() async throws {
    let id = UUID()
    try saveNightly(
      PromptTemplate(
        id: id, name: "Empty orchestration", body: "Nothing carried yet.", shape: .composite))
    let store = makeStore()
    let stale = LoopGraph(
      project: ProjectRef(path: "stale", name: "stale"),
      nodes: [LoopNode(title: "Mine", loopType: .sketch)])
    await store.handle(
      .createNode(
        NodeDraft(
          title: "Empty orchestration", loopType: .composite, subGraph: stale,
          templateFollow: TemplateFollow(id: id, name: "Empty orchestration"))))
    let compositeID = await store.graph.nodes[0].id

    await store.handle(.pilotComposite(compositeID))
    let graph = await store.graph
    #expect(graph.nodes[0].templateFollow?.missing == false)
    #expect(graph.nodes[0].subGraph?.nodes.map(\.title) == ["Mine"])
  }

  /// The `missing` warning is a fact about the graph, so it has to reach the clients
  /// watching it. The session sweeps are not commands and do not broadcast on their
  /// own; without an explicit one the warning would sit in the daemon forever.
  @Test
  func aMissingTemplateIsBroadcastToClients() async throws {
    let id = UUID()
    try saveNightly(
      PromptTemplate(
        id: id, name: "Nightly", body: "Check dependencies.", shape: .timeBased,
        settings: TemplateSettings(cadence: "daily")))
    let broadcasts = LockIsolated<[LoopGraph]>([])
    let store = GraphStore(
      onGraphChanged: { graph in broadcasts.withValue { $0.append(graph) } },
      onEnsureSession: { _, _ in },
      onResolveTemplate: { templateID, _ in
        self.storage.template(withID: templateID, projectPath: self.projectPath)
      })
    await store.handle(
      .createNode(
        NodeDraft(
          title: "Nightly", loopType: .timeBased, triggerPrompt: "/loop daily Check dependencies.",
          templateFollow: TemplateFollow(id: id, name: "Nightly"))))
    try FileManager.default.removeItem(
      at: storage.homeDirectory.appendingPathComponent("nightly.md"))

    broadcasts.withValue { $0.removeAll() }
    await store.ensureUnattendedSessions()
    #expect(broadcasts.value.last?.nodes[0].templateFollow?.missing == true)

    // A sweep that changed nothing is not a write: the graph is persisted on every
    // broadcast, and these run on a timer.
    broadcasts.withValue { $0.removeAll() }
    await store.ensureUnattendedSessions()
    #expect(broadcasts.value.isEmpty)
  }

  @Test
  func aRefreshRefusesToMangleTheLoop() async throws {
    // (resolvedForLaunch is the actor's own answer to "what would launch now")
    // A body still carrying {tokens} is not a brief — the snapshot stands.
    let id = UUID()
    try saveNightly(
      PromptTemplate(
        id: id, name: "Nightly", body: "Check {area} every night.",
        shape: .timeBased, settings: TemplateSettings(cadence: "daily")))
    let node = LoopNode(
      title: "Nightly", loopType: .timeBased, triggerPrompt: "/loop daily Check dependencies.",
      templateFollow: TemplateFollow(id: id, name: "Nightly"))
    let store = makeStore()
    let first = await store.resolvedForLaunch(node)
    #expect(first.triggerPrompt == "/loop daily Check dependencies.")

    // A template that has since committed to a different shape cannot be what a
    // timed loop follows — the snapshot stands there too.
    try saveNightly(
      PromptTemplate(
        id: id, name: "Nightly", body: "Now a goal brief.", shape: .goalBased,
        settings: TemplateSettings(cadence: "daily")))
    let second = await store.resolvedForLaunch(node)
    #expect(second.triggerPrompt == "/loop daily Check dependencies.")
  }

  @Test
  func theRefreshCarriesTheStopAfterPromiseForward() async throws {
    let id = UUID()
    try saveNightly(
      PromptTemplate(
        id: id, name: "Nightly", body: "Check dependencies and triage.",
        shape: .timeBased, settings: TemplateSettings(cadence: "daily")))
    let node = LoopNode(
      title: "Nightly", loopType: .timeBased,
      triggerPrompt: "/loop daily Check dependencies. Stop after 20 runs.",
      templateFollow: TemplateFollow(id: id, name: "Nightly"))
    let store = makeStore()
    let resolved = await store.resolvedForLaunch(node)
    #expect(
      resolved.triggerPrompt
        == "/loop daily Check dependencies and triage. Stop after 20 runs.")
  }
}
