import Foundation
import MailroomKit
import Testing

@testable import GraphcodeKit

/// The two-phase kill's bookkeeping (#196): a session is condemned on disk before the
/// first kill attempt, and absolved only once its death is confirmed — so a daemon that
/// dies mid-delete leaves the intent behind for the next startup's reap.
@Suite
struct CondemnedSessionsTests {
  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("condemned-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  @Test
  func condemnSurvivesANewInstance() async throws {
    let directory = try temporaryDirectory()
    await CondemnedSessions(directory: directory).condemn("graphcode-aaa")
    let names = await CondemnedSessions(directory: directory).names()
    #expect(names == ["graphcode-aaa"])
  }

  @Test
  func absolveRemovesOnlyItsName() async throws {
    let directory = try temporaryDirectory()
    let sessions = CondemnedSessions(directory: directory)
    await sessions.condemn("graphcode-aaa")
    await sessions.condemn("graphcode-bbb")
    await sessions.condemn("graphcode-aaa")
    await sessions.absolve("graphcode-aaa")
    let names = await sessions.names()
    #expect(names == ["graphcode-bbb"])
  }

  @Test
  func anEmptyListLeavesNoFileBehind() async throws {
    let directory = try temporaryDirectory()
    let sessions = CondemnedSessions(directory: directory)
    await sessions.condemn("graphcode-aaa")
    await sessions.absolve("graphcode-aaa")
    let file = directory.appendingPathComponent("condemned-sessions.txt")
    #expect(!FileManager.default.fileExists(atPath: file.path))
    let names = await sessions.names()
    #expect(names.isEmpty)
  }
}

/// `graphcode reap`'s selection logic (#197). The kill side rides the same confirmed
/// kill the delete path uses; what these pin is who is — and is not — an orphan.
@Suite
struct OrphanedSessionReaperTests {
  private let id1 = UUID()
  private let id2 = UUID()

  @Test
  func parsesOnlyGraphcodeSessionsOutOfTheListing() {
    let listing = """
        name=graphcode-\(id1.uuidString)\tpid=100\tclients=0\tpresence=busy
      → name=graphcode-\(id2.uuidString)\tpid=101\tclients=1\tcreated=1787089075
        name=my-other-session\tpid=102\tclients=0
        name=graphcode-not-a-uuid\tpid=103\tclients=0
      """
    let candidates = OrphanedSessionReaper.candidates(fromZmxList: listing)
    #expect(candidates.map(\.id) == [id1, id2])
    #expect(candidates.map(\.clients) == [0, 1])
  }

  @Test
  func skipsUnreachableAndIncompleteRows() {
    let listing = """
      name=graphcode-\(id1.uuidString) err=Timeout status=unreachable
      name=graphcode-\(id2.uuidString) pid=101
      """
    #expect(OrphanedSessionReaper.candidates(fromZmxList: listing).isEmpty)
  }

  @Test
  func aLiveNodeOrAnAttachedClientIsNeverAnOrphan() {
    let owned = OrphanedSessionReaper.Candidate(
      name: "graphcode-\(id1.uuidString)", id: id1, clients: 0)
    let attached = OrphanedSessionReaper.Candidate(
      name: "graphcode-\(id2.uuidString)", id: id2, clients: 1)
    let orphaned = OrphanedSessionReaper.Candidate(
      name: "graphcode-\(UUID().uuidString)", id: UUID(), clients: 0)
    let orphans = OrphanedSessionReaper.orphans(
      among: [owned, attached, orphaned], live: [id1])
    #expect(orphans == [orphaned])
  }

  @Test
  func liveIDsSpanEveryWorkspaceGraphAndQuickChats() throws {
    let workspace = FileManager.default.temporaryDirectory
      .appendingPathComponent("reap-ws-\(UUID().uuidString)")
    let workerID = UUID()
    let chatID = UUID()
    var composite = LoopNode(id: id1, title: "composite")
    composite.subGraph = LoopGraph(
      project: ProjectRef(path: "/tmp/p", name: "p"),
      nodes: [LoopNode(id: workerID, title: "worker")])
    let graph = LoopGraph(
      project: ProjectRef(path: "/tmp/p", name: "p"),
      nodes: [composite, LoopNode(id: id2, title: "plain")])

    let projects = workspace.appendingPathComponent("projects", isDirectory: true)
    try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    try JSONEncoder().encode(graph)
      .write(to: projects.appendingPathComponent("_tmp_p.json"))
    let chats = QuickChatStore(baseDirectory: workspace)
    chats.save([QuickChat(id: chatID, title: "chat")])

    let live = try #require(
      OrphanedSessionReaper.liveSessionIDs(workspaceDirectories: [workspace]))
    #expect(live == [id1, id2, workerID, chatID])
  }

  @Test
  func liveIDsIncludeEverySurfaceInTerminalLayouts() throws {
    let workspace = FileManager.default.temporaryDirectory
      .appendingPathComponent("reap-ws-\(UUID().uuidString)")
    let extraSurfaceID = UUID()
    let projects = workspace.appendingPathComponent("projects", isDirectory: true)
    try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    let graph = LoopGraph(
      project: ProjectRef(path: "/tmp/p", name: "p"),
      nodes: [LoopNode(id: id1, title: "owner")])
    try JSONEncoder().encode(graph)
      .write(to: projects.appendingPathComponent("_tmp_p.json"))
    let tab = TabLayout(primary: SurfaceRef(id: extraSurfaceID, launchesClaudeCode: false))
    TerminalLayoutStore(baseDirectory: workspace).save(
      TerminalLayout(tabs: [tab], selectedTabID: tab.id), forNode: id1)

    let live = try #require(
      OrphanedSessionReaper.liveSessionIDs(workspaceDirectories: [workspace]))
    #expect(live == [id1, extraSurfaceID])
  }

  @Test
  func aDeletedNodesStaleLayoutKeepsNoSessionsLive() throws {
    let workspace = FileManager.default.temporaryDirectory
      .appendingPathComponent("reap-ws-\(UUID().uuidString)")
    let extraSurfaceID = UUID()
    let tab = TabLayout(primary: SurfaceRef(id: extraSurfaceID, launchesClaudeCode: false))
    TerminalLayoutStore(baseDirectory: workspace).save(
      TerminalLayout(tabs: [tab], selectedTabID: tab.id), forNode: id1)

    let live = try #require(
      OrphanedSessionReaper.liveSessionIDs(workspaceDirectories: [workspace]))
    #expect(live.isEmpty)
  }

  /// #307 moved the Mailroom out of the graph file and into `<name>.mailroom.json`
  /// beside it. This scan took every `.json` under `projects/` for a graph, so the room
  /// looked like a graph it could not decode and `reap` aborted — on every workspace, for
  /// good, and with a message ("refusing to guess") that reads as caution rather than
  /// breakage. `reap` is the recovery tool for a machine out of PTYs, so it was broken
  /// exactly when it is needed. Saved through `ProjectPersistence` rather than by writing
  /// a hand-picked filename, so the test tracks the name the app actually mints.
  @Test
  func aRoomFileBesideItsGraphDoesNotStopAReap() throws {
    let workspace = FileManager.default.temporaryDirectory
      .appendingPathComponent("reap-ws-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: workspace) }
    var graph = LoopGraph(
      project: ProjectRef(path: "/tmp/p", name: "p"), nodes: [LoopNode(id: id1, title: "loop")])
    graph.mailroom = [
      MailroomPost(
        id: 1, at: Date(timeIntervalSince1970: 1), authorID: nil, author: "a peer",
        topic: nil, body: "a notice, so the room gets a file of its own")
    ]
    ProjectPersistence(baseDirectory: workspace).saveGraph(graph)

    let projects = workspace.appendingPathComponent("projects", isDirectory: true)
    let written = try FileManager.default.contentsOfDirectory(atPath: projects.path).sorted()
    #expect(written.count == 2, "the graph and its room, or this no longer reproduces")

    let live = try #require(
      OrphanedSessionReaper.liveSessionIDs(workspaceDirectories: [workspace]),
      "a room file beside a graph must not read as state the reap cannot account for")
    #expect(live == [id1])
  }

  /// The other half of the same rule, and the reason this is not simply "skip what will
  /// not decode": a *graph* that cannot be read still owns sessions nobody can enumerate,
  /// so the reap must keep refusing rather than sweep them.
  @Test
  func aCorruptGraphStillStopsAReap() throws {
    let workspace = FileManager.default.temporaryDirectory
      .appendingPathComponent("reap-ws-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: workspace) }
    let projects = workspace.appendingPathComponent("projects", isDirectory: true)
    try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    try Data("{ not a graph".utf8)
      .write(to: projects.appendingPathComponent("_tmp_p.json"))

    #expect(OrphanedSessionReaper.liveSessionIDs(workspaceDirectories: [workspace]) == nil)
  }

  /// What keeps the rule from rotting into a stale list of names: whatever
  /// `ProjectPersistence` writes beside a graph has to be something this scan recognises
  /// as a sidecar. Add a sidecar without registering its suffix and this fails here,
  /// rather than silently disabling `reap` again months later.
  @Test
  func everyFileWrittenBesideAGraphIsRecognisedAsASidecar() throws {
    let workspace = FileManager.default.temporaryDirectory
      .appendingPathComponent("reap-ws-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: workspace) }
    var graph = LoopGraph(
      project: ProjectRef(path: "/tmp/p", name: "p"), nodes: [LoopNode(id: id1, title: "loop")])
    graph.mailroom = [
      MailroomPost(
        id: 1, at: Date(timeIntervalSince1970: 1), authorID: nil, author: "a peer",
        topic: nil, body: "a notice")
    ]
    ProjectPersistence(baseDirectory: workspace).saveGraph(graph)

    let projects = workspace.appendingPathComponent("projects", isDirectory: true)
    let beside = try FileManager.default.contentsOfDirectory(atPath: projects.path)
      .filter { $0 != "_tmp_p.json" }
    #expect(!beside.isEmpty)
    for name in beside {
      #expect(
        ProjectPersistence.isSidecarFileName(name),
        "\(name) is written beside a graph but no sidecar suffix claims it")
    }
  }

  @Test
  func currentOverrideDirectoryJoinsDiscoveredWorkspacesOnce() {
    let defaultWorkspace = URL(fileURLWithPath: "/tmp/.graphcode")
    let override = URL(fileURLWithPath: "/tmp/.graphcode.dev")
    let directories = OrphanedSessionReaper.workspaceDirectoriesForReap(
      discovered: [defaultWorkspace, override], current: override)
    #expect(directories == [defaultWorkspace, override])
  }

  /// A graph this build cannot decode still owns its sessions. Refusing to answer is
  /// what keeps the reap from shooting them.
  @Test
  func anUndecodableGraphAbortsTheCount() throws {
    let workspace = FileManager.default.temporaryDirectory
      .appendingPathComponent("reap-ws-\(UUID().uuidString)")
    let projects = workspace.appendingPathComponent("projects", isDirectory: true)
    try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    try Data("not a graph".utf8).write(to: projects.appendingPathComponent("_tmp_p.json"))
    #expect(OrphanedSessionReaper.liveSessionIDs(workspaceDirectories: [workspace]) == nil)
  }

  @Test
  func anUndecodableLayoutAbortsTheCount() throws {
    let workspace = FileManager.default.temporaryDirectory
      .appendingPathComponent("reap-ws-\(UUID().uuidString)")
    let projects = workspace.appendingPathComponent("projects", isDirectory: true)
    try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    let graph = LoopGraph(
      project: ProjectRef(path: "/tmp/p", name: "p"),
      nodes: [LoopNode(id: id1, title: "owner")])
    try JSONEncoder().encode(graph)
      .write(to: projects.appendingPathComponent("_tmp_p.json"))
    let layouts = workspace.appendingPathComponent("terminal-layouts", isDirectory: true)
    try FileManager.default.createDirectory(at: layouts, withIntermediateDirectories: true)
    try Data("not a layout".utf8).write(
      to: layouts.appendingPathComponent("\(id1.uuidString).json"))
    #expect(OrphanedSessionReaper.liveSessionIDs(workspaceDirectories: [workspace]) == nil)
  }
}
