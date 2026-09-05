import MailroomKit
import ComposableArchitecture
import Foundation
import GraphcodeKit
import Testing

@testable import graphcode

/// `SINCE YOU LOOKED` in the rail's MAILROOM section is about the person at the
/// screen, exactly as it is two sections up — never the loop's own sync cursor.
@Suite
struct MailroomSinceYouLookedTests {
  private let projectPath = "/tmp/since-you-looked-\(UUID().uuidString)"

  private func makeStore(
    graph: LoopGraph, railVisible: Bool, folded: Bool = false
  ) -> TestStoreOf<LoopWorkspaceFeature> {
    let node = graph.nodes.first!
    var state = LoopWorkspaceFeature.State(
      node: node, graph: graph, layout: .defaultLayout(forNode: node.id),
      projectPath: projectPath, projectName: "p")
    state.isRailVisible = railVisible
    state.isMailroomFolded = folded
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
    graph.nodes.append(LoopNode(title: "Worker", lastMailroomRead: loopCursor))
    for id in noteIDs {
      graph.mailroom.append(
        MailroomPost(
          id: id, at: Date(), authorID: nil, author: "a human", topic: nil, body: "n\(id)"))
    }
    return graph
  }

  /// The loop may have synced everything; the human has looked at nothing.
  @Test
  func unreadIsTheHumansNotTheLoops() {
    let graph = makeGraph(noteIDs: [1, 2, 3], loopCursor: 3)
    #expect(MailroomPresentation.unreadNoticeCount(graph: graph, seenPostID: nil) == 3)
    #expect(MailroomPresentation.unreadNoticeCount(graph: graph, seenPostID: 2) == 1)
    #expect(MailroomPresentation.unreadNoticeCount(graph: graph, seenPostID: 3) == 0)
  }

  @Test
  @MainActor
  func leavingWithTheBoardOnScreenMarksItLooked() async {
    let store = makeStore(graph: makeGraph(noteIDs: [1, 2, 3], loopCursor: nil), railVisible: true)

    await store.send(.workspaceLeft)

    #expect(store.state.seenMailroomPostID == 3)
    #expect(LoopWorkspaceRail.loadSeenMailroomPost(forProjectPath: projectPath) == 3)
  }

  /// A hidden rail showed no posts; leaving must not clear a badge nobody could read.
  @Test
  @MainActor
  func leavingWithTheRailHiddenDoesNotMarkItLooked() async {
    let store = makeStore(
      graph: makeGraph(noteIDs: [1, 2, 3], loopCursor: nil), railVisible: false)

    await store.send(.workspaceLeft)

    #expect(store.state.seenMailroomPostID == nil)
    #expect(LoopWorkspaceRail.loadSeenMailroomPost(forProjectPath: projectPath) == nil)
  }

  @Test
  @MainActor
  func leavingWithTheSectionFoldedDoesNotMarkItLooked() async {
    let store = makeStore(
      graph: makeGraph(noteIDs: [1, 2], loopCursor: nil), railVisible: true, folded: true)

    await store.send(.workspaceLeft)

    #expect(store.state.seenMailroomPostID == nil)
  }

  /// A record (mirrored `node send`) is not a note: it is folded away, so it must not
  /// be what "looked" advances to, or a badge could count something never drawn.
  @Test
  @MainActor
  func lookedAdvancesToTheNewestNoteNotTheNewestRecord() async {
    var graph = makeGraph(noteIDs: [1, 2], loopCursor: nil)
    graph.mailroom.append(
      MailroomPost(
        id: 3, at: Date(), authorID: nil, author: "a human", topic: "direct",
        body: "@Worker: hi", kind: .letter))
    let store = makeStore(graph: graph, railVisible: true)

    await store.send(.workspaceLeft)

    #expect(store.state.seenMailroomPostID == 2)
  }
}
