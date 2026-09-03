import Foundation
import Testing

@testable import GraphcodeKit

/// One project, named several ways, has to stay one project.
///
/// Opening is create-if-missing — that is how `graphcode status <folder>` adds a folder
/// from a shell — and every path a client named went straight through it. A loop names
/// paths constantly: its own worktree, its working directory, its project spelled with a
/// trailing slash. Each of those became a second project with its own graph, its own
/// recents entry and its own sidebar row under the same name, and the child loops the
/// agent created went into it, where nothing was watching.
///
/// A codespace made it certain rather than possible. A remote path cannot be checked
/// against this filesystem, so *every* spelling of one was openable.
@Suite
struct DuplicateProjectPathTests {
  private static let codespace = "codespace://curly-space-guide/workspaces/widget"

  private func makeRegistryAndPersistence() -> (ProjectRegistry, ProjectPersistence) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("graphcode-tests-\(UUID().uuidString)", isDirectory: true)
    return (
      ProjectRegistry(persistenceDirectory: directory), ProjectPersistence(baseDirectory: directory)
    )
  }

  @Test
  func remoteSpellingsOfOnePathCanonicalizeTogether() {
    for spelling in [
      "codespace://curly-space-guide/workspaces/widget/",
      "codespace://curly-space-guide/workspaces//widget",
      "codespace://curly-space-guide/workspaces/./widget",
      "codespace://curly-space-guide/workspaces/other/../widget",
    ] {
      #expect(ProjectRegistry.canonicalize(spelling) == Self.codespace)
    }
    #expect(
      ProjectRegistry.canonicalize("ssh://dev@build-box:2222/home/dev/widget/")
        == "ssh://dev@build-box:2222/home/dev/widget")
    // Different hosts are different projects, however alike the directory looks.
    #expect(
      ProjectRegistry.canonicalize("codespace://other-space/workspaces/widget") != Self.codespace)
  }

  @Test
  func threeSpellingsOfOneCodespaceAreOneProject() async {
    let (registry, persistence) = makeRegistryAndPersistence()
    let app = UUID()
    await registry.addConnection(id: app, fileDescriptor: -1)
    await registry.handle(.restoreOpenProjects, connectionID: app)
    await registry.handle(.openProject(path: Self.codespace), connectionID: app)

    let shell = UUID()
    await registry.addConnection(id: shell, fileDescriptor: -1)
    for spelling in ["\(Self.codespace)/", "codespace://curly-space-guide/workspaces//widget"] {
      await registry.handle(.openProject(path: spelling), connectionID: shell)
    }

    #expect(persistence.loadRecentProjects().map(\.path) == [Self.codespace])
    #expect(persistence.loadOpenProjects() == [Self.codespace])
  }

  @Test
  func aLoopsWorktreeIsItsProjectRatherThanANewOne() async {
    let (registry, persistence) = makeRegistryAndPersistence()
    let app = UUID()
    await registry.addConnection(id: app, fileDescriptor: -1)
    await registry.handle(.restoreOpenProjects, connectionID: app)
    await registry.handle(.openProject(path: Self.codespace), connectionID: app)

    let shell = UUID()
    await registry.addConnection(id: shell, fileDescriptor: -1)
    await registry.handle(
      .openProject(path: "\(Self.codespace)/worktrees/fix-215"), connectionID: shell)

    #expect(persistence.loadRecentProjects().map(\.path) == [Self.codespace])
  }

  @Test
  func aRemoteProjectNobodyAddedIsRefusedFromAShell() async {
    let (registry, persistence) = makeRegistryAndPersistence()
    let shell = UUID()
    await registry.addConnection(id: shell, fileDescriptor: -1)
    await registry.handle(.openProject(path: Self.codespace), connectionID: shell)

    #expect(persistence.loadRecentProjects().isEmpty)

    guard
      case .refused(let reason) = await registry.routing(for: Self.codespace, isSidebar: false)
    else {
      Issue.record("a remote project the daemon has never seen should be refused")
      return
    }
    #expect(reason.contains("graphcode projects"))

    // The app adds it — validated over ssh first — and then the same shell can reach it.
    #expect(
      await registry.routing(for: Self.codespace, isSidebar: true) == .project(Self.codespace))
  }

  @Test
  func theAppStillOpensANestedFolderAsItsOwnProject() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("nested-\(UUID().uuidString)", isDirectory: true)
    let nested = root.appendingPathComponent("packages/api", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let (registry, persistence) = makeRegistryAndPersistence()
    let app = UUID()
    await registry.addConnection(id: app, fileDescriptor: -1)
    await registry.handle(.restoreOpenProjects, connectionID: app)
    await registry.handle(.openProject(path: root.path), connectionID: app)
    await registry.handle(.openProject(path: nested.path), connectionID: app)

    #expect(persistence.loadOpenProjects().count == 2)

    // The same folder named by a shell client is the project it sits in, not a third one.
    let shell = UUID()
    await registry.addConnection(id: shell, fileDescriptor: -1)
    await registry.handle(
      .openProject(path: nested.appendingPathComponent("src").path), connectionID: shell)
    #expect(persistence.loadOpenProjects().count == 2)
  }

  @Test
  func aFolderThatIsNotThereIsRefusedRatherThanIgnored() async {
    let (registry, _) = makeRegistryAndPersistence()
    guard
      case .refused(let reason) = await registry.routing(
        for: "/workspaces/widget", isSidebar: false)
    else {
      Issue.record("a path naming no folder should be refused")
      return
    }
    #expect(reason.contains("/workspaces/widget"))
  }

  /// What a daemon that ran before this fix left behind: the same codespace in the
  /// sidebar three times. The empty ones go on the next launch; one that collected loops
  /// stays, because those loops are somebody's work and a merged-away row is a row nobody
  /// can find again.
  @Test
  func emptyTwinsAreClearedOutOnTheNextLaunchAndOnesWithLoopsAreNot() async {
    let (registry, persistence) = makeRegistryAndPersistence()
    let twinWithLoops = "\(Self.codespace)//"
    persistence.saveOpenProjects([Self.codespace, "\(Self.codespace)/", twinWithLoops])
    persistence.saveGraph(
      LoopGraph(
        project: ProjectRef(path: twinWithLoops, name: "widget"),
        nodes: [
          LoopNode(
            title: "Child", loopType: .turnBased, checkDescription: "Sound?",
            firstInstruction: "Work")
        ]))

    let app = UUID()
    await registry.addConnection(id: app, fileDescriptor: -1)
    await registry.handle(.restoreOpenProjects, connectionID: app)

    #expect(persistence.loadOpenProjects() == [Self.codespace, twinWithLoops])
  }

  @Test
  func theDeepestKnownProjectWins() {
    let known: Set<String> = ["/repo", "/repo/packages/api"]
    #expect(
      ProjectRegistry.project(containing: "/repo/packages/api/src", in: known)
        == "/repo/packages/api")
    #expect(ProjectRegistry.project(containing: "/repo/docs", in: known) == "/repo")
    #expect(ProjectRegistry.project(containing: "/elsewhere", in: known) == nil)
    // A prefix that isn't a path boundary is not containment.
    #expect(ProjectRegistry.project(containing: "/repository/docs", in: known) == nil)
  }
}
