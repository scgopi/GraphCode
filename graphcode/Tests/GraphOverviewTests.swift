import ComposableArchitecture
import Foundation
import GraphcodeKit
import IdentifiedCollections
import Testing

@testable import graphcode

/// The Graph view's layout (docs/06-ux-terminals.md#the-graph-view) — every open
/// folder's loops on one canvas, each folder in a lane band of its own, with each
/// composite's sub-graph drawn inside the card that owns it.
///
/// The layout is tested as a pure value rather than through the view: what matters is
/// that nothing in the workspace can be missing from the picture and that everything
/// drawn has somewhere to hang from. Both are statements about the layout, not about
/// SwiftUI. What the view's own controls *do* is the exception at the bottom — the card
/// `+` is the one thing here that changes the workspace rather than describing it.
@Suite
struct GraphOverviewTests {
  private static let projectA = ProjectRef(path: "/tmp/project-a", name: "project-a")
  private static let projectB = ProjectRef(path: "/tmp/project-b", name: "project-b")

  @Test
  func everyOpenFolderGetsALaneBandOfItsOwn() {
    let overview = GraphOverview(graphs: [
      LoopGraph(scope: .global),
      LoopGraph(project: Self.projectA, nodes: [LoopNode(title: "A", checkDescription: "?")]),
      LoopGraph(project: Self.projectB),
    ])

    // Two lanes, not three: an empty global graph is dropped outright. A *folder* with
    // no loops still gets one — that's how the overview says "nothing here yet" rather
    // than omitting the folder entirely.
    #expect(overview.folders.map(\.path) == [Self.projectA.path, Self.projectB.path])
    // The bands stack rather than overlap; that they do is the whole grouping claim.
    let bands = overview.folders.map(\.band)
    #expect(bands.allSatisfy { $0.height > 0 && $0.width > 0 })
    #expect(bands[0].maxY < bands[1].minY)
  }

  @Test
  func aLoopSitsInsideItsOwnFoldersBand() {
    // The band replaced a chip and a tether: "these loops belong to this folder" is now
    // said by containment, so containment is what has to hold.
    let overview = GraphOverview(graphs: [
      LoopGraph(
        project: Self.projectA,
        nodes: [LoopNode(title: "A", checkDescription: "?"), LoopNode(title: "B")]),
      LoopGraph(project: Self.projectB, nodes: [LoopNode(title: "C")]),
    ])

    for loop in overview.loops {
      let band = overview.folders.first { $0.path == loop.projectPath }?.band
      #expect(band?.contains(loop.position) == true)
    }
  }

  @Test
  func theGlobalGraphsOwnTriggersGetALaneThatIsNotNamedGraph() {
    // Its triggers are loops like any other and still have to be visible — but a band
    // labelled "Graph" inside the Graph says nothing you didn't know from having clicked
    // Graph to get here. It is captioned for what it is: loops belonging to no folder.
    let trigger = LoopNode(title: "watch inbox", loopType: .timeBased, triggerPrompt: "/loop 1h")
    let overview = GraphOverview(graphs: [
      LoopGraph(scope: .global, nodes: [trigger]),
      LoopGraph(project: Self.projectA, nodes: [LoopNode(title: "A", checkDescription: "?")]),
    ])

    #expect(overview.folders.count == 2)
    let global = overview.folders.first { $0.isGlobal }
    #expect(global?.name != "Graph")
    let triggerCard = overview.loops.first { $0.id == trigger.id }
    #expect(global?.band.contains(triggerCard?.position ?? .zero) == true)
  }

  @Test
  func aLanesCaptionCountsOffTheSameRollupTheMonitorReads() {
    // Not a second count: the second half names the graph's own `aggregateState` and
    // counts the nodes in it, so a lane can't call a folder fine while the sidebar's
    // monitor says it isn't.
    let running = LoopGraph(
      project: Self.projectA,
      nodes: [
        LoopNode(title: "a", state: .running), LoopNode(title: "b", state: .running),
        LoopNode(title: "c", state: .idle),
      ])
    let broken = LoopGraph(
      project: Self.projectB,
      nodes: [LoopNode(title: "d", state: .failed), LoopNode(title: "e", state: .running)])

    #expect(GraphOverview.caption(for: running) == "3 loops · 2 running")
    #expect(GraphOverview.caption(for: broken) == "2 loops · 1 failed")
    #expect(GraphOverview.caption(for: LoopGraph(project: Self.projectA)) == nil)
  }

  @Test
  func aGlobalGraphWithNoTriggersTakesUpNoRoomAtAll() {
    // The common case — nobody has added a global trigger — must not leave a band of
    // blank canvas above the folders with nothing to explain it.
    let withGlobal = GraphOverview(graphs: [
      LoopGraph(scope: .global),
      LoopGraph(project: Self.projectA, nodes: [LoopNode(title: "A", checkDescription: "?")]),
    ])
    let withoutGlobal = GraphOverview(graphs: [
      LoopGraph(project: Self.projectA, nodes: [LoopNode(title: "A", checkDescription: "?")])
    ])
    #expect(withGlobal.folders.map(\.band) == withoutGlobal.folders.map(\.band))
    #expect(withGlobal.loops.map(\.position) == withoutGlobal.loops.map(\.position))
  }

  @Test
  func aCompositeIsOneCardAndItsSubGraphIsNotExpanded() {
    // The Graph exists to show every loop in the workspace. A composite that fans out to
    // a dozen templates would bury the folder it sits in under a dozen things that
    // aren't running — its card carries the count instead, and its own canvas is where
    // its insides are for.
    let inner = LoopNode(title: "explore", checkDescription: "?")
    let deeper = LoopNode(title: "judge", checkDescription: "?")
    let nestedComposite = LoopNode(
      title: "sub-composite", loopType: .composite,
      subGraph: LoopGraph(project: Self.projectA, nodes: [deeper]))
    let composite = LoopNode(
      title: "pipeline", loopType: .composite,
      subGraph: LoopGraph(project: Self.projectA, nodes: [inner, nestedComposite]))
    let plain = LoopNode(title: "review", checkDescription: "?")

    let overview = GraphOverview(graphs: [
      LoopGraph(project: Self.projectA, nodes: [composite, plain])
    ])

    #expect(Set(overview.loops.map(\.node.title)) == ["pipeline", "review"])
    // Including the deeply nested one — recursion into a composite inside a composite is
    // exactly what this must not do.
    #expect(!overview.loops.contains { $0.node.title == "judge" })
    // And the folder chip counts what the sidebar counts, not what's hidden inside.
    #expect(overview.folders.first?.loopCount == 2)
    #expect(overview.loopCount == 2)
  }

  @Test
  func eachLoopCarriesTheFolderItBelongsToSoATapCanRouteToIt() {
    let loopA = LoopNode(title: "A", checkDescription: "?")
    let loopB = LoopNode(title: "B", checkDescription: "?")
    let overview = GraphOverview(graphs: [
      LoopGraph(project: Self.projectA, nodes: [loopA]),
      LoopGraph(project: Self.projectB, nodes: [loopB]),
    ])

    // The sidebar's node rows can rely on a project-scoped store; this canvas spans
    // several, so the path has to travel with the card or the tap has nowhere to go.
    #expect(overview.loops.first { $0.id == loopA.id }?.projectPath == Self.projectA.path)
    #expect(overview.loops.first { $0.id == loopB.id }?.projectPath == Self.projectB.path)
  }

  @Test
  func aFoldersHandoffsAreDrawnAndItsEntryPointsHangOffItsChip() throws {
    let first = LoopNode(title: "first", checkDescription: "?")
    let second = LoopNode(title: "second", checkDescription: "?")
    let graph = LoopGraph(
      project: Self.projectA, nodes: [first, second],
      edges: [LoopEdge(from: first.id, to: second.id, spec: EdgeSpec())])

    let overview = GraphOverview(graphs: [graph])

    let edges = overview.links.filter {
      if case .edge = $0.kind { return true }
      return false
    }
    #expect(edges.count == 1)

    // Only real edges are drawn now. The tethers that used to say "this is where the
    // folder begins" are gone with the start marker — the band says it by enclosing them.
    let band = try #require(overview.folders.first).band
    let entry = try #require(overview.loops.first { $0.id == first.id }).position
    #expect(band.contains(entry))
    #expect(overview.links.count == 1)
  }

  @Test
  func nothingOverlapsAndTheCanvasIsBigEnoughToHoldItAll() {
    // Six loops in one folder wraps onto a second row; the lane below has to start
    // clear of it, which is the one thing a hand-rolled lane layout gets wrong.
    let nodes = (0..<6).map { LoopNode(title: "loop-\($0)", checkDescription: "?") }
    let overview = GraphOverview(graphs: [
      LoopGraph(project: Self.projectA, nodes: IdentifiedArrayOf<LoopNode>(uniqueElements: nodes)),
      LoopGraph(project: Self.projectB, nodes: [LoopNode(title: "b", checkDescription: "?")]),
    ])

    let positions = overview.loops.map(\.position)
    #expect(Set(positions).count == positions.count)

    let laneA = overview.loops.filter { $0.projectPath == Self.projectA.path }.map(\.position.y)
    let laneB = overview.loops.filter { $0.projectPath == Self.projectB.path }.map(\.position.y)
    #expect((laneA.max() ?? 0) < (laneB.min() ?? 0))

    #expect(overview.size.height > (positions.map(\.y).max() ?? 0))
    #expect(overview.size.width > (positions.map(\.x).max() ?? 0))
  }

  @Test
  func anEmptyWorkspaceLaysOutNothingAtAll() {
    let overview = GraphOverview(graphs: [])
    #expect(overview.isEmpty)
    #expect(overview.loops.isEmpty)
    #expect(overview.links.isEmpty)
  }

  /// A folder with no loops yet still draws its chip, so the overview is *not* empty —
  /// `isEmpty` is what gates the "Nothing running yet" overlay, and it used to sit on
  /// top of that chip telling you to open a folder you'd already opened.
  @Test
  func aFolderWithNoLoopsIsNotAnEmptyOverview() {
    let overview = GraphOverview(graphs: [LoopGraph(project: Self.projectA)])
    #expect(!overview.isEmpty)
    #expect(overview.folders.count == 1)
    #expect(overview.loops.isEmpty)
    // Still a band a row tall, so the lane below doesn't jam against a caption-height
    // sliver — the same rule the old lane layout had.
    #expect((overview.folders.first?.band.height ?? 0) > CanvasBand.captionHeight)
  }

  @Test
  func theGlobalGraphIsNamedForWhatItShowsRatherThanForTheDaemon() {
    // The sidebar row's label comes straight from here.
    #expect(LoopGraph(scope: .global).project.name == "Graph")
  }

  @Test
  func everyRootGetsItsOwnPortRatherThanALineToOneDot() {
    // The case the start marker failed: ten unwired loops fanned ten tethers out of a
    // single dot. Roots now carry the fact themselves, so N of them cost N ports.
    let first = LoopNode(title: "first")
    let second = LoopNode(title: "second")
    let third = LoopNode(title: "third")
    let overview = GraphOverview(graphs: [
      LoopGraph(
        project: Self.projectA, nodes: [first, second, third],
        edges: [
          LoopEdge(from: first.id, to: third.id), LoopEdge(from: second.id, to: third.id),
        ])
    ])

    let roles = Dictionary(
      uniqueKeysWithValues: overview.loops.map { ($0.node.title, $0.entryRole) })
    #expect(roles["first"] == .entry)
    #expect(roles["second"] == .entry)
    #expect(roles["third"] == .interior)
    // Two ports, on the leading edge of each root's card, for the band's rail to reach.
    #expect(overview.folders.first?.entryPorts.count == 2)
  }

  @Test
  func aLoopWiredToNothingStillHangsOffTheOrigin() {
    // It is still marked as the accident it probably is — dashed border, desaturated
    // stripe — but it gets a port and a line, because a card floating in the middle of a
    // canvas is how the whole thing went back to reading as scattered cards.
    let overview = GraphOverview(graphs: [
      LoopGraph(project: Self.projectA, nodes: [LoopNode(title: "loose")])
    ])

    #expect(overview.loops.first?.entryRole == .unwired)
    #expect(overview.folders.first?.entryPorts.count == 1)
  }

  @Test
  func beginningsStackDownTheFirstColumnAndChainsFlowRight() {
    // The layout the origin dot depends on. Filling rows left-to-right put every
    // rootless card side by side, which hid the fan behind them: cards draw over the
    // connectors, so they showed only in the gaps and read as card-chained-to-card.
    let root = LoopNode(title: "root")
    let downstream = LoopNode(title: "downstream")
    let loose = LoopNode(title: "loose")
    let overview = GraphOverview(graphs: [
      LoopGraph(
        project: Self.projectA, nodes: [downstream, root, loose],
        edges: [LoopEdge(from: root.id, to: downstream.id)])
    ])

    let at = Dictionary(uniqueKeysWithValues: overview.loops.map { ($0.node.title, $0.position) })
    // Both beginnings in the same column, on different rows.
    #expect(at["root"]?.x == at["loose"]?.x)
    #expect(at["root"]?.y != at["loose"]?.y)
    // The chain continues rightward on its own row.
    #expect((at["downstream"]?.x ?? 0) > (at["root"]?.x ?? 0))
    #expect(at["downstream"]?.y == at["root"]?.y)
  }

  @Test
  func theOriginDotHasALaneOfItsOwnLeftOfEveryCard() {
    // It used to sit 34pt left of the leading port, which put it outside the band and
    // clipped it and its caption against the edge.
    let overview = GraphOverview(graphs: [
      LoopGraph(project: Self.projectA, nodes: [LoopNode(title: "a")])
    ])
    let band = overview.folders.first?.band
    let port = overview.folders.first?.entryPorts.first

    #expect((port?.x ?? 0) - (band?.minX ?? 0) >= CanvasBand.originLane)
  }

  @Test
  func aCycleOnlyComponentIsMarkedAsOneRatherThanGivenAFakeRoot() {
    let maker = LoopNode(title: "maker")
    let reviewer = LoopNode(title: "reviewer")
    let overview = GraphOverview(graphs: [
      LoopGraph(
        project: Self.projectA, nodes: [maker, reviewer],
        edges: [
          LoopEdge(from: maker.id, to: reviewer.id),
          LoopEdge(from: reviewer.id, to: maker.id),
        ])
    ])

    #expect(overview.loops.allSatisfy { $0.entryRole == .cycleOnly })
    // A closed cycle is the one thing that gets neither a port nor a line: every node in
    // it is handed off to, so there is no honest place for the graph to begin.
    #expect(overview.folders.first?.entryPorts.isEmpty == true)
  }

  @Test
  func aLaneWithNothingHappeningCountsItsBeginningsInstead() {
    // "10 loops · 10 idle" is a count of the absence of news. How many places the lane
    // starts is a fact worth the same row.
    let first = LoopNode(title: "first", state: .idle)
    let second = LoopNode(title: "second", state: .idle)
    let graph = LoopGraph(
      project: Self.projectA, nodes: [first, second],
      edges: [LoopEdge(from: first.id, to: second.id)])

    #expect(GraphOverview.caption(for: graph) == "2 loops · 1 entry point")
  }

  /// The card `+` sends this — and the Graph view is the *global* graph's canvas, so the
  /// one way it could go wrong is filing the new loop there instead of with its parent.
  /// A cross-folder handoff is not expressible (docs/02-graph-of-loops.md), so the child
  /// has to land in the folder the parent already belongs to.
  @Test
  @MainActor
  func aChildCreatedFromTheGraphViewLandsInItsParentsFolder() async {
    let parent = LoopNode(title: "Research", checkDescription: "Sound?")
    var state = AppFeature.State()
    state.projects.append(ProjectFeature.State(graph: LoopGraph(scope: .global)))
    state.projects.append(
      ProjectFeature.State(graph: LoopGraph(project: Self.projectA, nodes: [parent])))
    state.selectedProjectPath = LoopGraphScope.globalPath

    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.gitClient.listWorktrees = { _ in [] }
    }
    store.exhaustivity = .off

    await store.send(
      .projects(.element(id: Self.projectA.path, action: .addChildNodeTapped(parent.id))))

    #expect(store.state.projects[id: Self.projectA.path]?.showingNewNodeForm == true)
    #expect(store.state.projects[id: Self.projectA.path]?.draftParentNodeID == parent.id)
    #expect(store.state.projects[id: LoopGraphScope.globalPath]?.showingNewNodeForm == false)
  }
}
