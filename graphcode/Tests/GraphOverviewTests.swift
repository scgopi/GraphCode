import Foundation
import GraphcodeKit
import IdentifiedCollections
import Testing

@testable import graphcode

/// The Graph view's layout (docs/06-ux-terminals.md#the-graph-view) — every open
/// folder's loops on one canvas, hanging off a single start node, with each composite's
/// sub-graph drawn inside the card that owns it.
///
/// Tested as a pure value rather than through the view: what matters is that nothing in
/// the workspace can be missing from the picture and that everything drawn has somewhere
/// to hang from. Both are statements about the layout, not about SwiftUI.
@Suite
struct GraphOverviewTests {
  private static let projectA = ProjectRef(path: "/tmp/project-a", name: "project-a")
  private static let projectB = ProjectRef(path: "/tmp/project-b", name: "project-b")

  @Test
  func everyOpenFolderGetsALaneTetheredToTheOneStartNode() {
    let overview = GraphOverview(graphs: [
      LoopGraph(scope: .global),
      LoopGraph(project: Self.projectA, nodes: [LoopNode(title: "A", checkDescription: "?")]),
      LoopGraph(project: Self.projectB),
    ])

    // Two folders, not three: the global graph gets no chip of its own. A chip labelled
    // "Graph" inside the Graph, tethered to the Graph's start node, says nothing.
    #expect(overview.folders.map(\.path) == [Self.projectA.path, Self.projectB.path])
    // A *folder* with no loops still gets a lane — that's how the overview says "nothing
    // here yet" rather than omitting the folder entirely.
    #expect(overview.folders.map(\.path).contains(Self.projectB.path))

    let tethered = Set(
      overview.links.filter { $0.kind == .tether && $0.from == overview.start }.map(\.to))
    #expect(tethered == Set(overview.folders.map(\.position)))
  }

  @Test
  func theGlobalGraphsOwnTriggersHangStraightOffTheStartNode() {
    // No chip for the Graph, but its triggers are loops like any other and still have to
    // be visible — they're entry points that belong to no folder, so the start node is
    // exactly what they hang from.
    let trigger = LoopNode(title: "watch inbox", loopType: .timeBased, triggerPrompt: "/loop 1h")
    let overview = GraphOverview(graphs: [
      LoopGraph(scope: .global, nodes: [trigger]),
      LoopGraph(project: Self.projectA, nodes: [LoopNode(title: "A", checkDescription: "?")]),
    ])

    #expect(overview.folders.count == 1)
    let triggerCard = overview.loops.first { $0.id == trigger.id }
    #expect(triggerCard != nil)
    #expect(
      overview.links.contains {
        $0.kind == .tether && $0.from == overview.start && $0.to == triggerCard?.position
      })
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
    #expect(withGlobal.folders.map(\.position) == withoutGlobal.folders.map(\.position))
    #expect(withGlobal.loops.map(\.position) == withoutGlobal.loops.map(\.position))
    #expect(withGlobal.start == withoutGlobal.start)
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
      title: "sub-composite", loopType: .proactive,
      subGraph: LoopGraph(project: Self.projectA, nodes: [deeper]))
    let composite = LoopNode(
      title: "pipeline", loopType: .proactive,
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

    // `second` is handed off to, so only `first` is an entry point — anchoring both
    // would say the graph has two beginnings when it has one.
    let chip = try #require(overview.folders.first).position
    let entry = try #require(overview.loops.first { $0.id == first.id }).position
    let anchored = overview.links.filter { $0.kind == .tether && $0.from == chip }.map(\.to)
    #expect(anchored == [entry])
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

  @Test
  func theGlobalGraphIsNamedForWhatItShowsRatherThanForTheDaemon() {
    // The sidebar row's label comes straight from here.
    #expect(LoopGraph(scope: .global).project.name == "Graph")
  }
}
