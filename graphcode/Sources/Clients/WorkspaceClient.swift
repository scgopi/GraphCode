import AppKit
import Dependencies
import Foundation
import GraphcodeKit

/// Finding, creating and opening workspaces — the app-side half of `Workspace`, which
/// knows about directories but nothing about running apps.
///
/// A workspace is opened by launching a **second instance of this app** with
/// `GRAPHCODE_SUPPORT_DIR` pointed at its directory. There is no in-process alternative:
/// the support directory is resolved through a process-wide static that some thirty call
/// sites read, from the graph store to the daemon socket to the `zmx` binary's path, so
/// one process serves exactly one workspace. That instance gets its own Dock tile, which
/// is also what makes a workspace draggable onto a second monitor.
struct WorkspaceClient: Sendable {
  var list: @Sendable () -> [Workspace]
  var create: @Sendable (String) throws -> Workspace
  /// Raises the instance that already has this workspace open, or launches one. Never
  /// opens a second app over a workspace already in use — that is two apps sharing one
  /// set of graphs and `zmx` session names, which is the failure `WorkspaceLock` exists
  /// to prevent.
  var open: @Sendable (Workspace) -> Void
  /// Tears a workspace down: its daemon out of launchd, its `zmx` sessions ended, its
  /// directory to the Trash. Throws `Workspace.Refusal` when it is not a workspace this
  /// may touch.
  var delete: @Sendable (Workspace) throws -> Void
  /// Moves a workspace to a new name, returning it. Same three refusals as `delete`, and
  /// for the same reason: both change the directory a running app resolves its paths
  /// through.
  var rename: @Sendable (Workspace, String) throws -> Workspace
  /// Workspaces open in *other* instances right now. Asked before an update swaps the
  /// bundle, since every workspace runs from the same copy in /Applications.
  /// What each workspace holds and whether a window has it — for the switcher's rows,
  /// keyed by workspace id.
  var summarize: @Sendable ([Workspace]) -> [String: Workspace.Summary]
  /// The invitation this workspace was opened with, if it has not been answered yet —
  /// what raises the starter dialog. See `WorkspaceStarter`.
  var starterInvitation: @Sendable () -> WorkspaceStarter.Invitation?
  /// Applied the moment it is picked, like the tour's page: through `SettingsModel`, not
  /// the store underneath it, or the Settings pane would keep showing the old value.
  var applyDefaultBackend: @Sendable (CLISessionBackendKind) async -> Void
  /// Answered — by choosing or by skipping. Either way the dialog does not come back.
  var finishStarter: @Sendable () -> Void
  var otherOpen: @Sendable () -> [Workspace]
  /// Asks those instances to quit, and waits — briefly — for them to actually go.
  var quit: @Sendable ([Workspace]) async -> Void
}

extension WorkspaceClient: DependencyKey {
  static let liveValue = WorkspaceClient(
    list: { Workspace.all() },
    create: { name in
      let created = try Workspace.create(name: name)
      // The creating workspace is the one that knows what to suggest: the agent this
      // person is already using, read from *this* workspace's settings.
      WorkspaceStarter.invite(created, suggesting: GraphcodeSettingsStore.load().defaultBackend)
      return created
    },
    open: { workspace in
      if let existing = runningInstance(of: workspace) {
        existing.activate()
        return
      }
      let configuration = NSWorkspace.OpenConfiguration()
      configuration.createsNewApplicationInstance = true
      configuration.environment = [SupportDirectory.environmentKey: workspace.url.path]
      NSWorkspace.shared.openApplication(
        at: Bundle.main.bundleURL, configuration: configuration, completionHandler: nil)
    },
    delete: { workspace in
      if let refusal = workspace.refusal(for: .delete) { throw refusal }

      // Order matters. The agent is `KeepAlive`, so a daemon still loaded over a deleted
      // directory is restarted by launchd and recreates it — the workspace comes back
      // from the dead, empty. Take launchd out of it first.
      DaemonBootstrap.removeLaunchAgent(for: workspace)

      // Then the sessions. These are the running agents: `zmx` outlives every app, so a
      // session missed here is a CLI left talking to a graph that no longer exists, for
      // as long as the machine is up. Killed through *this* workspace's `zmx` binary
      // because the one in the doomed directory is about to go — the server they both
      // talk to is the same one either way.
      endSessions(workspace.contents().sessionNames)

      // Trash rather than delete: this is someone's work, and the directory is the only
      // copy of it. Recoverable for as long as they haven't emptied the Trash.
      var trashed: NSURL?
      try FileManager.default.trashItem(at: workspace.url, resultingItemURL: &trashed)
    },
    rename: { workspace, name in
      if let refusal = workspace.refusal(for: .rename) { throw refusal }
      return try workspace.renamed(to: name)
    },
    summarize: { workspaces in
      Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0.summary()) })
    },
    starterInvitation: { WorkspaceStarter.pending() },
    applyDefaultBackend: { backend in
      // The file first, and unconditionally: this runs moments after a new workspace's
      // window opens, when nothing has necessarily read a setting yet, and routing the
      // write through the live model made the pick depend on that model already
      // existing. Six workspaces were created with the starter answered and not one
      // settings.json was written.
      GraphcodeSettingsStore.setDefaultBackend(backend)
      // Then the live model, so the Settings pane shows the choice and its next save
      // does not write back over it — the lesson `OnboardingView` records.
      await MainActor.run { SettingsModel.shared.settings = GraphcodeSettingsStore.load() }
    },
    finishStarter: { WorkspaceStarter.clear() },
    otherOpen: {
      let current = Workspace.current
      return Workspace.all()
        .filter { $0.id != current.id }
        .filter { runningInstance(of: $0) != nil }
    },
    quit: { workspaces in
      let running = workspaces.compactMap(runningInstance(of:))
      for application in running { application.terminate() }

      // Waited on rather than fired and forgotten: the point is to have them gone
      // *before* /Applications is replaced, since a running app whose bundle has been
      // swapped underneath it is reading pages that no longer exist. Bounded, because a
      // window that will not quit must not strand the update — the human already chose
      // to go ahead.
      let deadline = Date().addingTimeInterval(10)
      while Date() < deadline, running.contains(where: { !$0.isTerminated }) {
        try? await Task.sleep(for: .milliseconds(100))
      }
    })

  static let testValue = WorkspaceClient(
    list: { [.default] },
    create: { Workspace(slug: $0, url: URL(fileURLWithPath: "/tmp/\($0)")) },
    open: { _ in },
    delete: { _ in },
    rename: { workspace, name in
      Workspace(slug: name, url: workspace.url.deletingLastPathComponent())
    },
    summarize: { _ in [:] },
    starterInvitation: { nil },
    applyDefaultBackend: { _ in },
    finishStarter: {},
    otherOpen: { [] },
    quit: { _ in })

  /// `zmx kill` per session, best effort: a name that is already gone exits non-zero and
  /// that is the healthy case, not something to abandon the deletion over.
  private static func endSessions(_ names: [String]) {
    guard ZmxLocator.isInstalled, !names.isEmpty else { return }
    let process = Process()
    process.executableURL = ZmxLocator.binaryURL
    process.arguments = ["kill"] + names + ["--force"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
    process.waitUntilExit()
  }

  /// The pid file names a process; this checks it is actually one of ours before
  /// activating it, since pids are reused and the recorded process may be long gone and
  /// its number since handed to something unrelated.
  private static func runningInstance(of workspace: Workspace) -> NSRunningApplication? {
    guard let pid = WorkspaceLock.holder(of: workspace),
      let application = NSRunningApplication(processIdentifier: pid),
      application.bundleIdentifier == Bundle.main.bundleIdentifier
    else { return nil }
    return application
  }
}

extension DependencyValues {
  var workspaceClient: WorkspaceClient {
    get { self[WorkspaceClient.self] }
    set { self[WorkspaceClient.self] = newValue }
  }
}
