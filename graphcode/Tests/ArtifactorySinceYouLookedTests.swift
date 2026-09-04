import ArtifactoryKit
import ComposableArchitecture
import Foundation
import GraphcodeKit
import Testing

@testable import graphcode

/// `SINCE YOU LOOKED` in the rail's ARTIFACTORY section is about the person at the
/// screen, exactly as it is two sections up — never the loop's own sync cursor.
@Suite
struct ArtifactorySinceYouLookedTests {
  private let projectPath = "/tmp/since-you-looked-\(UUID().uuidString)"

  private func makeStore(
    graph: LoopGraph, railVisible: Bool, folded: Bool = false
  ) -> TestStoreOf<LoopWorkspaceFeature> {
    let node = graph.nodes.first!
    var state = LoopWorkspaceFeature.State(
      node: node, graph: graph, layout: .defaultLayout(forNode: node.id),
      projectPath: projectPath, projectName: "p")
    state.isRailVisible = railVisible
    state.isArtifactoryFolded = folded
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("graphcode-tests-\(UUID().uuidString)", isDirectory: true)
    let store = TestStore(initialState: state) {
      LoopWorkspaceFeature()
    } withDependencies: {
      $0.terminalLayoutStore = TerminalLayoutStore(baseDirectory: directory)
    }
    store.exhaustivity = .off
    return store
  }

  private func makeGraph(noteIDs: [Int], loopCursor: Int?) -> LoopGraph {
    var graph = LoopGraph(project: ProjectRef(path: projectPath, name: "p"))
    graph.nodes.append(LoopNode(title: "Worker", lastArtifactoryRead: loopCursor))
    for id in noteIDs {
      graph.artifactory.append(
        ArtifactoryPost(
          id: id, at: Date(), authorID: nil, author: "a human", topic: nil, body: "n\(id)"))
    }
    return graph
  }

  /// The loop may have synced everything; the human has looked at nothing.
  @Test
  func unreadIsTheHumansNotTheLoops() {
    let graph = makeGraph(noteIDs: [1, 2, 3], loopCursor: 3)
    #expect(ArtifactoryPresentation.unreadCount(graph: graph, seenPostID: nil) == 3)
    #expect(ArtifactoryPresentation.unreadCount(graph: graph, seenPostID: 2) == 1)
    #expect(ArtifactoryPresentation.unreadCount(graph: graph, seenPostID: 3) == 0)
  }

  @Test
  @MainActor
  func leavingWithTheBoardOnScreenMarksItLooked() async {
    let store = makeStore(graph: makeGraph(noteIDs: [1, 2, 3], loopCursor: nil), railVisible: true)

    await store.send(.workspaceLeft)

    #expect(store.state.seenArtifactoryPostID == 3)
    #expect(LoopWorkspaceRail.loadSeenArtifactoryPost(forProjectPath: projectPath) == 3)
  }

  /// A hidden rail showed no posts; leaving must not clear a badge nobody could read.
  @Test
  @MainActor
  func leavingWithTheRailHiddenDoesNotMarkItLooked() async {
    let store = makeStore(
      graph: makeGraph(noteIDs: [1, 2, 3], loopCursor: nil), railVisible: false)

    await store.send(.workspaceLeft)

    #expect(store.state.seenArtifactoryPostID == nil)
    #expect(LoopWorkspaceRail.loadSeenArtifactoryPost(forProjectPath: projectPath) == nil)
  }

  @Test
  @MainActor
  func leavingWithTheSectionFoldedDoesNotMarkItLooked() async {
    let store = makeStore(
      graph: makeGraph(noteIDs: [1, 2], loopCursor: nil), railVisible: true, folded: true)

    await store.send(.workspaceLeft)

    #expect(store.state.seenArtifactoryPostID == nil)
  }

  /// A delivery receipt is folded away, so it must not be what "looked" advances to, or
  /// a badge could count something never drawn.
  @Test
  @MainActor
  func lookedAdvancesToTheNewestPostNotTheNewestReceipt() async {
    var graph = makeGraph(noteIDs: [1, 2], loopCursor: nil)
    graph.artifactory.append(receipt(id: 3))
    let store = makeStore(graph: graph, railVisible: true)

    await store.send(.workspaceLeft)

    #expect(store.state.seenArtifactoryPostID == 2)
  }

  /// The other half of #273: a mirrored `node send` carries the whole text a loop typed,
  /// so it is shown, counted, and cleared like any other post. It prunes on the record
  /// budget all the same — that is a quota, not a verdict on whether anyone should read
  /// it.
  @Test
  func aWrittenMessageIsShownAndCounted() {
    var graph = makeGraph(noteIDs: [1, 2], loopCursor: nil)
    graph.artifactory.append(
      ArtifactoryPost(
        id: 3, at: Date(), authorID: nil, author: "Peer", topic: "direct",
        body: "@Worker: truncation is not the mechanism", kind: .record, wasWritten: true))
    graph.artifactory.append(receipt(id: 4))

    #expect(ArtifactoryPresentation.posts(in: graph).map(\.id) == [1, 2, 3])
    #expect(ArtifactoryPresentation.receipts(in: graph).map(\.id) == [4])
    #expect(ArtifactoryPresentation.unreadCount(graph: graph, seenPostID: 2) == 1)
  }

  /// The badge must stay clearable: everything it counts has to be something leaving the
  /// workspace marks as looked at.
  @Test
  @MainActor
  func aWrittenMessageClearsTheBadge() async {
    var graph = makeGraph(noteIDs: [1, 2], loopCursor: nil)
    graph.artifactory.append(
      ArtifactoryPost(
        id: 3, at: Date(), authorID: nil, author: "Peer", topic: "direct",
        body: "@Worker: correction accepted", kind: .record, wasWritten: true))
    graph.artifactory.append(receipt(id: 4))
    let store = makeStore(graph: graph, railVisible: true)

    await store.send(.workspaceLeft)

    #expect(store.state.seenArtifactoryPostID == 3)
    #expect(
      ArtifactoryPresentation.unreadCount(
        graph: graph, seenPostID: store.state.seenArtifactoryPostID) == 0)
  }

  private func receipt(id: Int) -> ArtifactoryPost {
    ArtifactoryPost(
      id: id, at: Date(), authorID: nil, author: "a human", topic: "handoff",
      body: "@Worker: Peer finished and handed its work off to you.", kind: .record)
  }
}
