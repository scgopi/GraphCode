import Foundation
import Testing

@testable import GraphcodeKit

/// Workspaces — separate support directories, each with its own graphs, daemon and loops.
///
/// The load-bearing assertions here are the ones about the *default* workspace: it has to
/// come out of this feature with the same directory, the same daemon label and the same
/// launch agent bytes it had before, or every existing install would have its daemon
/// bounced and its agent renamed on first launch.
@Suite
struct WorkspaceTests {
  /// A short home, deliberately: `FileManager.temporaryDirectory` is a ~50-byte
  /// `/var/folders/…` path, and a workspace socket under it breaches `sun_path` — which
  /// the validator correctly refuses, failing every test that only wanted a scratch
  /// directory.
  private func makeHome() -> URL {
    let home = URL(fileURLWithPath: "/tmp")
      .appendingPathComponent("gcw-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    return home
  }

  @Test
  func theDefaultWorkspaceKeepsTheDirectoryAndLabelItAlwaysHad() {
    let workspace = Workspace.default

    #expect(workspace.isDefault)
    #expect(workspace.slug.isEmpty)
    #expect(workspace.url.path == SupportDirectory.defaultURL.path)
    #expect(workspace.url.lastPathComponent == ".graphcode")
    #expect(workspace.daemonLabel == "dev.graphcode.graphcoded")
  }

  @Test
  func theDefaultDirectoryIgnoresTheSupportDirectoryOverride() {
    // `defaultURL` is the scan root for finding the other workspaces. Were it to follow
    // `GRAPHCODE_SUPPORT_DIR` the way `url` does, a named workspace would look for its
    // siblings inside itself and find none of them.
    #expect(
      SupportDirectory.defaultURL.path
        == (NSHomeDirectory() as NSString).appendingPathComponent(".graphcode"))
  }

  @Test
  func aNamedWorkspaceIsASiblingWithALabelOfItsOwn() {
    let home = makeHome()
    defer { try? FileManager.default.removeItem(at: home) }

    let url = Workspace.url(forSlug: "client-work", home: home)
    #expect(url.lastPathComponent == ".graphcode-client-work")

    let workspace = Workspace.workspace(for: url, home: home)
    #expect(!workspace.isDefault)
    #expect(workspace.slug == "client-work")
    #expect(workspace.name == "client-work")
    #expect(workspace.daemonLabel == "dev.graphcode.graphcoded.client-work")
  }

  @Test
  func aDirectoryThisFeatureNeverNamedStillGetsALabelOfItsOwn() {
    // A developer running `GRAPHCODE_SUPPORT_DIR=~/.graphcode.dev` shared the installed
    // app's label until now, so launching that build rewrote the real launch agent and
    // pointed launchd at a DerivedData daemon.
    let home = makeHome()
    defer { try? FileManager.default.removeItem(at: home) }

    let workspace = Workspace.workspace(
      for: home.appendingPathComponent(".graphcode.dev", isDirectory: true), home: home)
    #expect(!workspace.isDefault)
    #expect(workspace.daemonLabel == "dev.graphcode.graphcoded.graphcode-dev")
  }

  @Test
  func namesBecomeSlugsThatAreSafeAsDirectoriesAndLabels() {
    #expect(Workspace.slug(from: "Client Work") == "client-work")
    #expect(Workspace.slug(from: "  spaced  out  ") == "spaced-out")
    #expect(Workspace.slug(from: "OSS/side—projects!") == "oss-side-projects")
    #expect(Workspace.slug(from: "…") == "")
    #expect(Workspace.slug(from: "Café Zürich") == "cafe-zurich")
  }

  @Test
  func aNameThatIsAllPunctuationIsRejectedRatherThanTurnedIntoADotDirectory() {
    let home = makeHome()
    defer { try? FileManager.default.removeItem(at: home) }

    #expect(Workspace.problem(name: "///", home: home) == .empty)
    #expect(Workspace.problem(name: "", home: home) == .empty)
  }

  @Test
  func anExistingWorkspaceIsNotSilentlyReused() throws {
    // Creating over a live workspace would hand two apps one set of graphs — the exact
    // thing this feature exists to keep apart.
    let home = makeHome()
    defer { try? FileManager.default.removeItem(at: home) }

    _ = try Workspace.create(name: "work", home: home)
    #expect(Workspace.problem(name: "work", home: home) == .taken("work"))
    #expect(Workspace.problem(name: "WORK", home: home) == .taken("work"))
  }

  @Test
  func aNameThatWouldOverflowTheSocketPathIsRefusedWithTheNumbers() {
    // `sun_path` is 104 bytes on Darwin. Without this the bind just fails at runtime and
    // the workspace looks like a daemon that won't start.
    let home = URL(fileURLWithPath: "/Users/" + String(repeating: "u", count: 60))
    let problem = Workspace.problem(
      name: String(repeating: "w", count: 30), home: home,
      fileManager: FileManager.default)

    guard case .pathTooLong(let length) = problem else {
      Issue.record("expected a path-length problem, got \(String(describing: problem))")
      return
    }
    #expect(length > Workspace.maximumSocketPathLength)
  }

  @Test
  func creatingAWorkspaceMakesItsDirectoryAndNothingElse() throws {
    let home = makeHome()
    defer { try? FileManager.default.removeItem(at: home) }

    let workspace = try Workspace.create(name: "Side Projects", home: home)
    #expect(workspace.slug == "side-projects")
    #expect(FileManager.default.fileExists(atPath: workspace.url.path))
    // Its `bin/`, launch agent and daemon are the opening instance's job, exactly as they
    // are for a first install of the default workspace.
    #expect(
      (try? FileManager.default.contentsOfDirectory(atPath: workspace.url.path))?.isEmpty == true)
  }

  @Test
  func theListIsTheDefaultPlusWhateverDirectoriesExist() throws {
    let home = makeHome()
    defer { try? FileManager.default.removeItem(at: home) }

    _ = try Workspace.create(name: "work", home: home)
    _ = try Workspace.create(name: "oss", home: home)
    // Not a workspace: no prefix. The scan must not offer to open someone's dotfiles.
    try FileManager.default.createDirectory(
      at: home.appendingPathComponent(".ssh"), withIntermediateDirectories: true)

    let slugs = Workspace.all(home: home).map(\.slug)
    #expect(slugs.contains(""))
    #expect(slugs.contains("work"))
    #expect(slugs.contains("oss"))
    #expect(!slugs.contains("ssh"))
    // The default first, then the order they were made in — issue #175. Alphabetical is
    // what this was, and it is why "oss" used to arrive in front of a "work" that had
    // been ⌥⌘2 for a month.
    #expect(slugs.prefix(3) == ["", "work", "oss"])
  }

  @Test
  func creatingAWorkspaceOnlyEverAddsToTheEndOfTheList() throws {
    // The whole reason #175 is a bug and not a preference: ⌥⌘<n> is muscle memory, and
    // alphabetical order re-pointed those keys at different workspaces every time a name
    // sorted early. Dates are set explicitly rather than trusted to the order the
    // directories were made — the assertion is about the sort, not about the filesystem's
    // timestamp resolution.
    let home = makeHome()
    defer { try? FileManager.default.removeItem(at: home) }

    for (name, day) in [("work", 1.0), ("zebra", 2.0), ("alpha", 3.0)] {
      let workspace = try Workspace.create(name: name, home: home)
      try FileManager.default.setAttributes(
        [.creationDate: Date(timeIntervalSince1970: day * 86_400)],
        ofItemAtPath: workspace.url.path)
    }

    #expect(Workspace.all(home: home).map(\.slug).prefix(4) == ["", "work", "zebra", "alpha"])
  }

  @Test
  func renamingAWorkspaceKeepsItsPlaceInTheList() throws {
    // `moveItem` carries the creation date across, so the one gesture that changes a
    // workspace's name does not change which number switches to it.
    let home = makeHome()
    defer { try? FileManager.default.removeItem(at: home) }

    let first = try Workspace.create(name: "work", home: home)
    try FileManager.default.setAttributes(
      [.creationDate: Date(timeIntervalSince1970: 86_400)], ofItemAtPath: first.url.path)
    let second = try Workspace.create(name: "oss", home: home)
    try FileManager.default.setAttributes(
      [.creationDate: Date(timeIntervalSince1970: 172_800)], ofItemAtPath: second.url.path)

    _ = try first.renamed(to: "zzz last", home: home)

    #expect(Workspace.all(home: home).map(\.slug).prefix(3) == ["", "zzz-last", "oss"])
  }

  @Test
  func renamingMovesTheDirectoryAndRetiresTheOldAgent() throws {
    // The directory *is* the workspace, so a rename is a move — the graphs, layouts and
    // session ids inside go with it untouched, because none of them names the workspace.
    let home = makeHome()
    defer { try? FileManager.default.removeItem(at: home) }

    let workspace = try Workspace.create(name: "work", home: home)
    let projects = workspace.url.appendingPathComponent("projects", isDirectory: true)
    try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: projects.appendingPathComponent("_tmp_project.json"))

    let renamed = try workspace.renamed(to: "Client Work", home: home)

    #expect(renamed.slug == "client-work")
    #expect(renamed.daemonLabel == "dev.graphcode.graphcoded.client-work")
    #expect(!FileManager.default.fileExists(atPath: workspace.url.path))
    #expect(
      FileManager.default.fileExists(
        atPath: renamed.url.appendingPathComponent("projects/_tmp_project.json").path))
  }

  @Test
  func aRenameIsRefusedByTheSameNameRulesAsACreate() throws {
    let home = makeHome()
    defer { try? FileManager.default.removeItem(at: home) }

    let work = try Workspace.create(name: "work", home: home)
    _ = try Workspace.create(name: "oss", home: home)

    // Onto a name already in use — which would otherwise be a move onto a live directory.
    #expect(throws: Workspace.NameProblem.taken("oss")) {
      try work.renamed(to: "OSS", home: home)
    }
    #expect(throws: Workspace.NameProblem.empty) {
      try work.renamed(to: "///", home: home)
    }
    // Still where it was, under its own name.
    #expect(FileManager.default.fileExists(atPath: work.url.path))
  }

  @Test
  func bothChangesAreRefusedForTheDefaultTheCurrentAndAnOpenWorkspace() {
    let home = makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let work = Workspace(slug: "work", url: Workspace.url(forSlug: "work", home: home))
    let other = Workspace(slug: "oss", url: Workspace.url(forSlug: "oss", home: home))

    // The refusal names what was asked, so one alert serves both.
    #expect(
      Workspace.default.refusal(for: .rename, current: work) == .isDefault(.rename))
    #expect(
      Workspace.default.refusal(for: .rename, current: work)?.errorDescription
        == "The default workspace can't be renamed.")
    #expect(
      Workspace.default.refusal(for: .delete, current: work)?.errorDescription
        == "The default workspace can't be deleted.")
    // Renaming the workspace this window is using would move the directory it resolves
    // every path through, out from under itself.
    #expect(work.refusal(for: .rename, current: work) == .isCurrent(.rename))
    #expect(work.refusal(for: .rename, current: other) == nil)
  }

  @Test
  func deletionIsRefusedForTheDefaultTheCurrentAndAnOpenWorkspace() {
    let home = makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let work = Workspace(slug: "work", url: Workspace.url(forSlug: "work", home: home))
    let other = Workspace(slug: "oss", url: Workspace.url(forSlug: "oss", home: home))
    try? FileManager.default.createDirectory(at: work.url, withIntermediateDirectories: true)

    // The default workspace is every existing install's whole state.
    #expect(Workspace.default.refusal(for: .delete, current: work) == .isDefault(.delete))
    // Deleting the workspace this window is using would pull its graphs out from under a
    // live app.
    #expect(work.refusal(for: .delete, current: work) == .isCurrent(.delete))
    #expect(work.refusal(for: .delete, current: other) == nil)

    // And the same thing one process away: another instance has it open.
    WorkspaceLock.claim(work, pid: getpid())
    #expect(work.refusal(for: .delete, current: other) == .isOpen(pid: getpid(), .delete))
    WorkspaceLock.release(work, pid: getpid())
    #expect(work.refusal(for: .delete, current: other) == nil)
  }

  @Test
  func aWorkspacesContentsNameEverySessionItsDeletionMustEnd() throws {
    // A session missed here is an agent left running against a workspace that no longer
    // exists, for as long as the machine is up — zmx outlives every app. Extra tabs and
    // splits are surfaces of their own, so the graphs alone are not the whole answer.
    let home = makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let workspace = try Workspace.create(name: "work", home: home)

    let node = LoopNode(title: "a loop")
    var graph = LoopGraph(project: ProjectRef(path: "/tmp/project", name: "project"))
    graph.nodes.append(node)
    let projects = workspace.url.appendingPathComponent("projects", isDirectory: true)
    try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    try JSONEncoder().encode(graph)
      .write(to: projects.appendingPathComponent("_tmp_project.json"))

    let extraSurface = SurfaceRef(id: UUID(), launchesClaudeCode: false)
    var layout = TerminalLayout.defaultLayout(forNode: node.id)
    layout.tabs.append(TabLayout(primary: extraSurface))
    let layouts = workspace.url.appendingPathComponent("terminal-layouts", isDirectory: true)
    try FileManager.default.createDirectory(at: layouts, withIntermediateDirectories: true)
    try JSONEncoder().encode(layout)
      .write(to: layouts.appendingPathComponent("\(node.id.uuidString).json"))

    let contents = workspace.contents()
    #expect(contents.projects == 1)
    #expect(contents.loops == 1)
    #expect(contents.sessionNames.contains("graphcode-\(node.id.uuidString)"))
    #expect(contents.sessionNames.contains("graphcode-\(extraSurface.id.uuidString)"))
    #expect(contents.sessionNames.count == 2)
  }

  @Test
  func aGraphNamedLikeASidecarIsCountedAndItsRoomIsNot() throws {
    // A project path ending in `.mailroom` mints a graph file that carries the sidecar
    // suffix. A room — valid or corrupt — never decodes as a graph, so a room is skipped
    // by the decode and a sidecar-named graph is not.
    let home = makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let workspace = try Workspace.create(name: "work", home: home)

    let node = LoopNode(title: "a loop")
    var graph = LoopGraph(project: ProjectRef(path: "/tmp/x.mailroom", name: "project"))
    graph.nodes.append(node)
    let projects = workspace.url.appendingPathComponent("projects", isDirectory: true)
    try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    try JSONEncoder().encode(graph)
      .write(to: projects.appendingPathComponent("_tmp_x.mailroom.json"))
    try Data("[]".utf8)
      .write(to: projects.appendingPathComponent("_tmp_x.mailroom.mailroom.json"))

    let contents = workspace.contents()
    #expect(contents.projects == 1)
    #expect(contents.loops == 1)
    #expect(contents.sessionNames == ["graphcode-\(node.id.uuidString)"])
  }

  @Test
  func aLiveClaimIsNotStolenByASecondProcess() {
    // The test host launches the app, which claims the default workspace on the way up.
    // Claiming unconditionally would have it overwrite a running window's pid, and once
    // the host exited the workspace would read as free while that window still had it.
    let home = makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let workspace = Workspace(slug: "work", url: home)

    #expect(WorkspaceLock.claim(workspace, pid: getpid()))
    #expect(!WorkspaceLock.claim(workspace, pid: 4242))
    #expect(WorkspaceLock.holder(of: workspace) == getpid())

    // A dead holder is no holder: a crashed app must not lock the workspace out forever.
    WorkspaceLock.release(workspace, pid: getpid())
    WorkspaceLock.claim(workspace, pid: 999_999)
    #expect(WorkspaceLock.claim(workspace, pid: getpid()))
    #expect(WorkspaceLock.holder(of: workspace) == getpid())
    WorkspaceLock.release(workspace, pid: getpid())
  }

  @Test
  func aWorkspaceRecordsWhichProcessHasItOpen() {
    let home = makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let workspace = Workspace(slug: "work", url: home)

    #expect(WorkspaceLock.holder(of: workspace) == nil)

    WorkspaceLock.claim(workspace, pid: getpid())
    #expect(WorkspaceLock.holder(of: workspace) == getpid())

    // A pid nothing is running under is not a claim — this is what a crashed app leaves
    // behind, and treating it as live would lock a workspace out until someone deleted a
    // file they have never heard of. Released first because a claim is not stolen from a
    // live holder; see `aLiveClaimIsNotStolenByASecondProcess`.
    WorkspaceLock.release(workspace, pid: getpid())
    WorkspaceLock.claim(workspace, pid: 999_999)
    #expect(WorkspaceLock.holder(of: workspace) == nil)

    // Releasing on behalf of a pid that no longer holds it must not clear the live claim:
    // an instance quitting after another took the workspace over.
    WorkspaceLock.claim(workspace, pid: getpid())
    WorkspaceLock.release(workspace, pid: 4242)
    #expect(WorkspaceLock.holder(of: workspace) == getpid())

    WorkspaceLock.release(workspace, pid: getpid())
    #expect(WorkspaceLock.holder(of: workspace) == nil)
  }
}
