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
}

extension WorkspaceClient: DependencyKey {
  static let liveValue = WorkspaceClient(
    list: { Workspace.all() },
    create: { try Workspace.create(name: $0) },
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
    })

  static let testValue = WorkspaceClient(
    list: { [.default] },
    create: { Workspace(slug: $0, url: URL(fileURLWithPath: "/tmp/\($0)")) },
    open: { _ in })

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
