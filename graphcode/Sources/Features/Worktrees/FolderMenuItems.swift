import AppKit
import ComposableArchitecture
import SwiftUI

/// The folder verbs worktree hygiene adds, shared between the sidebar row's menu and
/// the lane caption's — a lane band *is* the folder, so right-clicking either place
/// must offer the same things.
///
/// The trailing count on `Worktrees…` is the whole reason the item earns a slot: it
/// answers "is there anything to reclaim" without opening anything. With nothing
/// reclaimable the item stays, without a count.
struct FolderHygieneMenuItems: View {
  let store: StoreOf<AppFeature>
  let projectPath: String

  var body: some View {
    if AppWorktreesReducer.tracksWorktrees(projectPath) {
      Button(worktreesTitle) {
        store.send(.worktrees(.sweepRequested(projectPath: projectPath)))
      }
      Button("Project Settings…") {
        store.send(.worktrees(.settingsRequested(projectPath: projectPath)))
      }
      Button("Open in Finder") {
        NSWorkspace.shared.open(URL(fileURLWithPath: projectPath))
      }
    }
  }

  private var worktreesTitle: String {
    let reclaimable = store.worktreeStats[projectPath]?.reclaimable ?? 0
    return reclaimable > 0 ? "Worktrees… \(reclaimable)" : "Worktrees…"
  }
}
