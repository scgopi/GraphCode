import ComposableArchitecture
import Foundation
import GraphcodeKit
import Testing

@testable import graphcode

/// The open gate for blocked loops — `LoopNode.opensOnHumanTap` and what `.nodeTapped`
/// does on each side of it. Its own suite because the rule spans the domain (who may
/// open) and the app (what a refusal says), and because the #194 follow-up that
/// created it is exactly the kind of behavior a later fix could quietly regress.
@Suite
struct BlockedLoopGateTests {
  private static let projectA = ProjectRef(path: "/tmp/project-a", name: "project-a")

  private func makeTerminalLayoutStore() -> TerminalLayoutStore {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("graphcode-tests-\(UUID().uuidString)", isDirectory: true)
    return TerminalLayoutStore(baseDirectory: directory)
  }

  /// The whole gate, per loop type. An attended loop (turn-based, sketch) opens even
  /// blocked — a human's tap is what runs it, so the tap is the authorization. An
  /// unattended one needs a live session; without one, opening would start sequenced
  /// work the graph says must wait.
  @Test
  func opensOnHumanTapFollowsAttendanceAndPresence() {
    func node(_ type: LoopType, _ state: LoopState, presence: Presence? = nil) -> LoopNode {
      LoopNode(
        title: "N", loopType: type,
        presence: presence.map { PresenceReading(presence: $0, confidence: .reported) },
        state: state)
    }
    #expect(node(.turnBased, .blocked).opensOnHumanTap)
    #expect(node(.sketch, .blocked).opensOnHumanTap)
    #expect(!node(.goalBased, .blocked).opensOnHumanTap)
    #expect(!node(.timeBased, .blocked).opensOnHumanTap)
    #expect(node(.goalBased, .blocked, presence: .busy).opensOnHumanTap)
    #expect(node(.timeBased, .blocked, presence: .idle).opensOnHumanTap)
    #expect(node(.goalBased, .running).opensOnHumanTap)
    #expect(node(.turnBased, .idle).opensOnHumanTap)
  }

  /// What the refusal alert and the blocked card's tooltip name: the sources of the
  /// unfired sequencing edges into a node — never a `message` edge's, and never one
  /// that already fired.
  @Test
  func unfiredUpstreamTitlesNamesOnlyUnfiredSequencingSources() {
    let parent = LoopNode(title: "Parent", checkDescription: "c")
    let sibling = LoopNode(title: "Sibling", checkDescription: "c")
    let child = LoopNode(title: "Child", checkDescription: "c")
    let graph = LoopGraph(
      project: Self.projectA,
      nodes: [parent, sibling, child],
      edges: [
        LoopEdge(from: parent.id, to: child.id),
        LoopEdge(from: sibling.id, to: child.id, fireCount: 1),
        LoopEdge(from: child.id, to: parent.id, kind: .message),
      ])
    #expect(graph.unfiredUpstreamTitles(of: child.id) == ["Parent"])
    #expect(graph.unfiredUpstreamTitles(of: parent.id).isEmpty)
  }

  /// The #194 orchestration shape, from the human's side: a turn-based child wired in
  /// by a hand-off is `.blocked` with no session, and a turn-based loop only ever runs
  /// because a human opened it — so the tap is the authorization, not a violation of
  /// the sequencing. Refusing it left the child unreachable by every gesture the app
  /// has until its parent resolved.
  @Test
  @MainActor
  func blockedTurnBasedNodeOpensOnTap() async {
    var blockedNode = LoopNode(title: "Implement", checkDescription: "Correct?")
    blockedNode.state = .blocked
    var state = AppFeature.State()
    state.projects.append(
      ProjectFeature.State(graph: LoopGraph(project: Self.projectA, nodes: [blockedNode])))
    state.selectedProjectPath = Self.projectA.path

    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.terminalLayoutStore = makeTerminalLayoutStore()
    }
    store.exhaustivity = .off

    await store.send(
      .projects(.element(id: Self.projectA.path, action: .nodeTapped(blockedNode.id))))
    #expect(store.state.openLoop?.node.id == blockedNode.id)
    #expect(store.state.blockedLoopNotice == nil)
  }

  /// What stays gated: a blocked *unattended* loop with no session, where opening
  /// would start sequenced work early. The refusal must say so — a silent dead click
  /// is indistinguishable from a broken canvas — and name what the loop waits on.
  @Test
  @MainActor
  func blockedUnattendedNodeStaysGatedAndExplains() async {
    let parent = LoopNode(title: "Parent", checkDescription: "Done?")
    var blockedNode = LoopNode(
      title: "Fetch", loopType: .goalBased, goal: GoalSpec(summary: "fetch it"))
    blockedNode.state = .blocked
    var state = AppFeature.State()
    state.projects.append(
      ProjectFeature.State(
        graph: LoopGraph(
          project: Self.projectA, nodes: [parent, blockedNode],
          edges: [LoopEdge(from: parent.id, to: blockedNode.id)])))
    state.selectedProjectPath = Self.projectA.path

    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.terminalLayoutStore = makeTerminalLayoutStore()
    }
    store.exhaustivity = .off

    await store.send(
      .projects(.element(id: Self.projectA.path, action: .nodeTapped(blockedNode.id))))
    #expect(store.state.openLoop == nil)
    #expect(store.state.blockedLoopNotice?.message.contains("“Parent”") == true)

    await store.send(.blockedLoopNoticeDismissed)
    #expect(store.state.blockedLoopNotice == nil)
  }
}
