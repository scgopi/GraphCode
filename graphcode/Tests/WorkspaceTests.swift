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
    // The default first, then alphabetical — a list that reorders itself between openings
    // is a list nobody can build a habit on.
    #expect(slugs.prefix(3) == ["", "oss", "work"])
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
    // file they have never heard of.
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
