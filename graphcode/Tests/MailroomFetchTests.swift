import ComposableArchitecture
import Foundation
import GraphcodeKit
import MailroomKit
import Testing

@testable import graphcode

/// The app's half of the room's read path (issue #288): a `.graphChanged` snapshot
/// carries the room's digest and no posts, so the copy a project holds carries over
/// from broadcast to broadcast, and a digest that says the copy is stale is what asks
/// the daemon for a fresh one — never every broadcast, never the presence tick.
@Suite
struct MailroomFetchTests {
  private static let project = ProjectRef(path: "/tmp/project-a", name: "project-a")

  private actor Sent {
    private(set) var commands: [DaemonCommand] = []
    func append(_ command: DaemonCommand) { commands.append(command) }
  }

  private static func post(_ id: Int, _ body: String) -> MailroomPost {
    MailroomPost(
      id: id, at: Date(timeIntervalSince1970: TimeInterval(id)), authorID: nil,
      author: "a human", topic: nil, body: body)
  }

  private static let fetch = DaemonCommand.mailbox(
    projectPath: project.path, query: MailboxQuery(selection: .board, fullBodies: true))

  @Test
  @MainActor
  func aProjectAsksForTheRoomOnlyWhenTheDigestSaysItsCopyIsStale() async {
    let sent = Sent()
    var room = LoopGraph(project: Self.project)
    room.mailroom = [Self.post(1, "claiming #12")]
    let store = TestStore(
      initialState: ProjectFeature.State(graph: LoopGraph(project: Self.project))
    ) {
      ProjectFeature()
    } withDependencies: {
      $0.orchestratorClient.send = { command in await sent.append(command) }
    }
    store.exhaustivity = .off

    // A snapshot whose digest names a post this project has never seen: ask for it.
    await store.send(.daemonEvent(.graphChanged(room.wireSnapshot())))
    await store.finish()
    #expect(await sent.commands == [Self.fetch])
    #expect(store.state.graph.mailroom.isEmpty)
    // Not yet: the digest is held only once the posts it describes have arrived.
    #expect(store.state.graph.mailroomDigest == nil)

    // The answer is the copy from here on.
    let mailbox = Mailroom.serve(
      MailboxQuery(selection: .board, fullBodies: true), from: room.mailroom
    ) { _ in nil }
    await store.send(.daemonEvent(.mailbox(projectPath: Self.project.path, mailbox: mailbox)))
    #expect(store.state.graph.mailroom == room.mailroom)
    #expect(store.state.graph.mailroomDigest == mailbox.digest)

    // An unrelated broadcast — a presence tick, a rename — carries the copy over and
    // asks for nothing.
    var renamed = room
    renamed.nodes.append(LoopNode(title: "Newcomer", loopType: .turnBased))
    await store.send(.daemonEvent(.graphChanged(renamed.wireSnapshot())))
    await store.finish()
    #expect(await sent.commands == [Self.fetch])
    #expect(store.state.graph.mailroom == room.mailroom)
    #expect(store.state.graph.nodes.count == 1)

    // A post landing changes the digest, and the room is asked for again.
    var grown = renamed
    grown.mailroom.append(Self.post(2, "done with #12"))
    await store.send(.daemonEvent(.graphChanged(grown.wireSnapshot())))
    await store.finish()
    #expect(await sent.commands == [Self.fetch, Self.fetch])
    #expect(store.state.graph.mailroom == room.mailroom)
  }

  /// An answer that never lands — a swallowed send, a refusal — must not leave the
  /// project holding the new digest with the old posts: the next broadcast carrying
  /// that digest asks again.
  @Test
  @MainActor
  func aProjectWhoseFetchNeverLandsAsksAgain() async {
    let sent = Sent()
    var room = LoopGraph(project: Self.project)
    room.mailroom = [Self.post(1, "claiming #12")]
    let store = TestStore(
      initialState: ProjectFeature.State(graph: LoopGraph(project: Self.project))
    ) {
      ProjectFeature()
    } withDependencies: {
      $0.orchestratorClient.send = { command in await sent.append(command) }
    }
    store.exhaustivity = .off

    await store.send(.daemonEvent(.graphChanged(room.wireSnapshot())))
    await store.finish()
    #expect(await sent.commands.count == 1)

    // The answer never comes. The next broadcast carries the same digest.
    await store.send(.daemonEvent(.graphChanged(room.wireSnapshot())))
    await store.finish()
    #expect(await sent.commands.count == 2)
    #expect(store.state.graph.mailroom.isEmpty)

    // Once it lands, the same digest is current and nothing asks again.
    let mailbox = Mailroom.serve(
      MailboxQuery(selection: .board, fullBodies: true), from: room.mailroom
    ) { _ in nil }
    await store.send(.daemonEvent(.mailbox(projectPath: Self.project.path, mailbox: mailbox)))
    await store.send(.daemonEvent(.graphChanged(room.wireSnapshot())))
    await store.finish()
    #expect(await sent.commands.count == 2)
    #expect(store.state.graph.mailroom == room.mailroom)
  }

  /// The app's first snapshot of a project is held the same way: an answer that never
  /// lands is asked for again on the next broadcast.
  @Test
  @MainActor
  func theAppHoldsAFirstSnapshotWithoutItsDigest() async {
    let sent = Sent()
    var room = LoopGraph(project: Self.project)
    room.mailroom = [Self.post(1, "claiming #12")]
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.orchestratorClient.send = { command in await sent.append(command) }
    }
    store.exhaustivity = .off

    await store.send(.daemonEvent(.graphChanged(room.wireSnapshot())))
    await store.finish()
    #expect(await sent.commands == [Self.fetch])
    #expect(store.state.projects[id: Self.project.path]?.graph.mailroomDigest == nil)

    await store.send(.daemonEvent(.graphChanged(room.wireSnapshot())))
    await store.receive(\.projects)
    await store.finish()
    #expect(await sent.commands == [Self.fetch, Self.fetch])
  }

  /// A snapshot from a daemon that still ships posts keeps its own — nothing is
  /// carried over it, and nothing is asked for.
  @Test
  @MainActor
  func aSnapshotStillCarryingPostsIsTakenAsItIs() async {
    let sent = Sent()
    var room = LoopGraph(project: Self.project)
    room.mailroom = [Self.post(1, "claiming #12")]
    let store = TestStore(
      initialState: ProjectFeature.State(graph: LoopGraph(project: Self.project))
    ) {
      ProjectFeature()
    } withDependencies: {
      $0.orchestratorClient.send = { command in await sent.append(command) }
    }
    store.exhaustivity = .off

    await store.send(.daemonEvent(.graphChanged(room)))
    await store.finish()
    #expect(await sent.commands.isEmpty)
    #expect(store.state.graph.mailroom == room.mailroom)
  }

  /// The first sight of a project is the app's, not the project reducer's — the
  /// snapshot that *creates* the project row is what asks for its room; a project
  /// with an empty room is not asked about.
  @Test
  @MainActor
  func theAppAsksOnAProjectsFirstSnapshot() async {
    let sent = Sent()
    var room = LoopGraph(project: Self.project)
    room.mailroom = [Self.post(1, "claiming #12")]
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.orchestratorClient.send = { command in await sent.append(command) }
    }
    store.exhaustivity = .off

    await store.send(.daemonEvent(.graphChanged(room.wireSnapshot())))
    await store.finish()
    #expect(await sent.commands == [Self.fetch])

    let quiet = LoopGraph(project: ProjectRef(path: "/tmp/project-b", name: "project-b"))
    await store.send(.daemonEvent(.graphChanged(quiet.wireSnapshot())))
    await store.finish()
    #expect(await sent.commands == [Self.fetch])
  }

  /// An open workspace reads the room off its own graph: the answer reaches it, and
  /// the next broadcast reaches it with the copy still on.
  @Test
  @MainActor
  func anOpenWorkspaceReadsTheSameRoom() async {
    let node = LoopNode(title: "Research", checkDescription: "Sound?")
    var room = LoopGraph(project: Self.project, nodes: [node])
    room.mailroom = [Self.post(1, "claiming #12")]
    var state = AppFeature.State()
    state.projects.append(ProjectFeature.State(graph: room.wireSnapshot()))
    state.openLoop = LoopWorkspaceFeature.State(
      node: node, layout: .defaultLayout(forNode: node.id), projectPath: Self.project.path,
      projectName: Self.project.name)
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.orchestratorClient.send = { _ in }
    }
    store.exhaustivity = .off

    let mailbox = Mailroom.serve(
      MailboxQuery(selection: .board, fullBodies: true), from: room.mailroom
    ) { _ in nil }
    await store.send(.daemonEvent(.mailbox(projectPath: Self.project.path, mailbox: mailbox)))
    // The project's copy is the project reducer's to set, one hop down.
    await store.receive(\.projects)
    #expect(store.state.projects[id: Self.project.path]?.graph.mailroom == room.mailroom)
    #expect(store.state.openLoop?.graph.mailroom == room.mailroom)

    await store.send(.daemonEvent(.graphChanged(room.wireSnapshot())))
    await store.finish()
    #expect(store.state.openLoop?.graph.mailroom == room.mailroom)
    #expect(store.state.openLoop?.graph.nodes.count == 1)
  }
}
