import ComposableArchitecture
import Foundation
import GraphcodeKit

/// One loop's whole terminal workspace — tabs, each optionally split into two panes,
/// the way a supacode worktree's own terminal area works (drawn on for shape only, not
/// code) but scoped to exactly one loop's node instead of a worktree. Replaces Phase
/// 4's `LoopNodeDetailFeature`, which only ever showed a single terminal.
///
/// `layout` is persisted to disk (`TerminalLayoutStore`) on every mutation, keyed by
/// this loop's node id — reopening the same loop, even after quitting the app, loads
/// the same tabs/splits back. Nothing about *content* is persisted here: every
/// surface's actual terminal output lives in its own long-running `zmx` session, which
/// reattaches with full scrollback on its own.
@Reducer
struct LoopWorkspaceFeature {
  @ObservableState
  struct State: Equatable, Identifiable {
    var node: LoopNode
    var layout: TerminalLayout
    // The project folder every surface without its own worktree binding should open
    // in — a loop's shells shouldn't land in the app's own launch directory (usually
    // the user's home) just because this node has no worktree of its own yet.
    var projectPath: String
    /// What the folder header calls this workspace's project. Carried rather than
    /// derived from `projectPath`'s last component so it matches the sidebar exactly,
    /// including the global graph — whose path is a reserved URL, not a folder.
    var projectName: String

    var id: UUID { node.id }
  }

  enum Action {
    case newTabButtonTapped
    case tabSelected(UUID)
    case tabClosed(UUID)
    case selectNextTab
    case selectPreviousTab
    case splitButtonTapped(direction: SplitDirection)
    case paneClosed(tabID: UUID, surfaceID: UUID)
    case primarySurfaceExited(succeeded: Bool)
  }

  @Dependency(\.terminalLayoutStore) var terminalLayoutStore

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .newTabButtonTapped:
        let tab = TabLayout(primary: SurfaceRef(id: UUID(), launchesClaudeCode: false))
        state.layout.tabs.append(tab)
        state.layout.selectedTabID = tab.id
        persist(state)
        return .none

      case .tabSelected(let id):
        guard state.layout.tabs[id: id] != nil else { return .none }
        state.layout.selectedTabID = id
        persist(state)
        return .none

      case .tabClosed(let id):
        // A workspace always keeps at least one tab.
        guard state.layout.tabs.count > 1, let index = state.layout.tabs.index(id: id) else {
          return .none
        }
        state.layout.tabs.remove(id: id)
        if state.layout.selectedTabID == id {
          let fallbackIndex = min(index, state.layout.tabs.count - 1)
          state.layout.selectedTabID = state.layout.tabs[fallbackIndex].id
        }
        persist(state)
        return .none

      // ⌘→/⌘← step through tabs, wrapping at the ends — with one or two tabs this is
      // a no-op/toggle, which is fine, there's nowhere more useful to land.
      case .selectNextTab:
        step(&state, by: 1)
        return .none

      case .selectPreviousTab:
        step(&state, by: -1)
        return .none

      case .splitButtonTapped(let direction):
        guard var tab = state.layout.tabs[id: state.layout.selectedTabID], tab.secondary == nil
        else { return .none }
        tab.secondary = SurfaceRef(id: UUID(), launchesClaudeCode: false)
        tab.splitDirection = direction
        state.layout.tabs[id: tab.id] = tab
        persist(state)
        return .none

      case .paneClosed(let tabID, let surfaceID):
        guard var tab = state.layout.tabs[id: tabID] else { return .none }
        guard let secondary = tab.secondary else {
          // Not split — this pane is the whole tab, so closing it closes the tab.
          return .send(.tabClosed(tabID))
        }
        // Closing one side of a split keeps the other as the tab's single pane.
        if tab.primary.id == surfaceID {
          tab.primary = secondary
        }
        tab.secondary = nil
        state.layout.tabs[id: tabID] = tab
        persist(state)
        return .none

      // A loop resolves itself the moment its Claude Code session ends — there's no
      // separate human approve/reject step. `AppFeature` also reacts to this same
      // action to tell `graphcoded` about the resolution (it owns the connection),
      // which is what triggers automatic outgoing-edge firing.
      case .primarySurfaceExited(let succeeded):
        state.node.state = succeeded ? .succeeded : .failed
        return .none
      }
    }
  }

  private func step(_ state: inout State, by offset: Int) {
    guard let index = state.layout.tabs.index(id: state.layout.selectedTabID) else { return }
    let count = state.layout.tabs.count
    let nextIndex = ((index + offset) % count + count) % count
    state.layout.selectedTabID = state.layout.tabs[nextIndex].id
    persist(state)
  }

  private func persist(_ state: State) {
    terminalLayoutStore.save(state.layout, forNode: state.node.id)
  }
}
