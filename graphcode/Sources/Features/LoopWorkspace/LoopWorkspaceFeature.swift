import ComposableArchitecture
import Foundation
import GraphcodeKit

/// One loop's whole terminal workspace — tabs, each holding a tree of split panes (see
/// `SplitNode`), the way a supacode worktree's own terminal area works (drawn on for shape
/// only, not code) but scoped to exactly one loop's node instead of a worktree. Replaces
/// Phase 4's `LoopNodeDetailFeature`, which only ever showed a single terminal.
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
    /// The user clicked into one pane of a split. Sent by the surface itself on mouse
    /// down, which is the only unambiguous "I meant this one" there is.
    case paneFocused(tabID: UUID, surfaceID: UUID)
    case focusNextPane
    case focusPreviousPane
    case paneClosed(tabID: UUID, surfaceID: UUID)
    case primarySurfaceExited(succeeded: Bool)
  }

  @Dependency(\.terminalLayoutStore) var terminalLayoutStore
  /// Closing a tab or a pane is the one thing that should still end a surface. Switching
  /// loops deliberately doesn't — see `TerminalSurfaceStore` — so without telling it
  /// here, a closed pane's terminal would linger until it aged out of the cache.
  @Dependency(\.terminalSurfaceClient) var terminalSurfaceClient

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
        guard state.layout.tabs.count > 1, let index = state.layout.tabs.index(id: id),
          let tab = state.layout.tabs[id: id]
        else {
          return .none
        }
        terminalSurfaceClient.retire(tab.surfaces.map(\.id))
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

      // ⌘D / ⌘⇧D, and the two tab-strip buttons. Splitting is unbounded: it divides the
      // pane you are in, so pressing ⌘D three times gives four panes rather than two and
      // two ignored keystrokes.
      case .splitButtonTapped(let direction):
        guard var tab = state.layout.tabs[id: state.layout.selectedTabID] else { return .none }
        let addition = SurfaceRef(id: UUID(), launchesClaudeCode: false)
        // The focused pane is the one that divides — the same anchor supacode's terminal
        // splits at. Always splitting `primary` instead would drop every new pane next to
        // the first one, wherever you were actually working.
        tab.root = tab.root.splitting(tab.focusedSurface.id, with: addition, direction: direction)
        // The new pane takes the keyboard, matching every terminal that splits — you
        // asked for another shell because you want to type in it. Leaving focus behind
        // would also mean the pane you just created came up dimmed.
        tab.focusedSurfaceID = addition.id
        state.layout.tabs[id: tab.id] = tab
        persist(state)
        return .none

      case .paneFocused(let tabID, let surfaceID):
        guard var tab = state.layout.tabs[id: tabID], tab.isSplit else { return .none }
        guard tab.focusedSurfaceID != surfaceID else { return .none }
        tab.focusedSurfaceID = surfaceID
        state.layout.tabs[id: tabID] = tab
        persist(state)
        return .none

      // ⌘] / ⌘[, matching Ghostty's own goto_split next/previous keys. Steps through
      // the showing tab's panes in on-screen order, wrapping — clicking was the only
      // way to move between the halves of a split before this existed.
      case .focusNextPane:
        stepPaneFocus(&state, by: 1)
        return .none

      case .focusPreviousPane:
        stepPaneFocus(&state, by: -1)
        return .none

      case .paneClosed(let tabID, let surfaceID):
        guard var tab = state.layout.tabs[id: tabID] else { return .none }
        let paneOrder = tab.surfaces
        guard let closedIndex = paneOrder.firstIndex(where: { $0.id == surfaceID })
        else { return .none }
        guard let root = tab.root.removing(surfaceID) else {
          // The tab's only pane — closing it closes the tab.
          return .send(.tabClosed(tabID))
        }
        // Only the pane that went is retired. Every survivor is the same live terminal it
        // was, and is about to be re-mounted in the space the closed one gave up.
        terminalSurfaceClient.retire([surfaceID])
        tab.root = root
        if tab.focusedSurfaceID == surfaceID {
          // Where the keyboard lands, matching supacode (and Ghostty, which it follows):
          // the pane before the one that closed, or the new first pane if the one that
          // closed *was* first.
          let survivors = tab.surfaces
          tab.focusedSurfaceID = survivors[max(0, closedIndex - 1)].id
        }
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

  private func stepPaneFocus(_ state: inout State, by offset: Int) {
    guard var tab = state.layout.tabs[id: state.layout.selectedTabID], tab.isSplit else { return }
    let panes = tab.surfaces
    guard let index = panes.firstIndex(where: { $0.id == tab.focusedSurface.id }) else { return }
    let count = panes.count
    tab.focusedSurfaceID = panes[((index + offset) % count + count) % count].id
    state.layout.tabs[id: tab.id] = tab
    persist(state)
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
