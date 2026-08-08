import ComposableArchitecture
import SwiftUI

/// Hosts the two worktree-hygiene sheets on `AppView` — the sweeper and a folder's
/// settings. In a modifier of its own for the reason `UpdateDialogs` is: both must open
/// over a terminal as readily as over a canvas, and `AppView`'s dialog chain is already
/// more than the type-checker will sit through.
struct WorktreeDialogs: ViewModifier {
  @Bindable var store: StoreOf<AppFeature>

  func body(content: Content) -> some View {
    content
      .sheet(
        isPresented: Binding(
          get: { store.worktreeSweep != nil },
          set: { if !$0 { store.send(.worktrees(.sweepDismissed)) } })
      ) {
        if let sweepStore = store.scope(state: \.worktreeSweep, action: \.worktrees.sweep) {
          WorktreeSweepView(store: sweepStore)
        }
      }
      .sheet(
        isPresented: Binding(
          get: { store.projectSettingsPath != nil },
          set: { if !$0 { store.send(.worktrees(.settingsDismissed)) } })
      ) {
        if let path = store.projectSettingsPath {
          ProjectSettingsView(
            projectPath: path,
            projectName: store.projects[id: path]?.graph.project.name
              ?? (path as NSString).lastPathComponent
          )
          // Fresh identity per folder — a reused sheet showed one folder's thresholds
          // over another folder's name.
          .id(path)
        }
      }
  }
}
