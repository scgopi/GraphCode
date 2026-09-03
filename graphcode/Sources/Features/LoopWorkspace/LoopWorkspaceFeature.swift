import ComposableArchitecture
import Foundation
import GraphcodeKit

/// One loop's whole terminal workspace — tabs, each holding a tree of split panes (see
/// `SplitNode`), scoped to exactly one loop's node. Replaces
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
    /// The graph this loop belongs to, so the workspace can say what it hands off to
    /// without the terminal having to be closed to find out. Kept in sync by
    /// `AppFeature` alongside `node`, from the same broadcast — see the right rail
    /// (`LoopWorkspaceRail`), which is the only thing that reads it.
    ///
    /// A quick chat passes an empty one: it belongs to no graph, which is exactly what
    /// the rail should then have to say about it.
    var graph = LoopGraph(scope: .global)
    /// Whether the downstream rail is showing. In the reducer rather than in the view's
    /// `@State` because the *toggle* lives in the window toolbar, which `AppView` owns —
    /// and a control and the thing it controls cannot hold the answer separately.
    var isRailVisible = LoopWorkspaceRail.loadVisible()
    /// How wide the rail is, after any drag on its edge. Persisted like its visibility:
    /// someone who widened it to read beats did not mean only this session.
    var railWidth = LoopWorkspaceRail.loadWidth()
    /// Whether the summary section is collapsed to one line. Persisted beside the rail's
    /// own visibility, and for the same reason: both are choices about how much of the
    /// window a person wants back, and neither should have to be remade every launch.
    var isSummaryFolded = LoopWorkspaceRail.loadSummaryFolded()
    /// Whether the board section is collapsed to its header. Persisted separately from the
    /// summary's fold: they answer different questions, and someone who wants the sentence
    /// and not the diagram — or the diagram and not the sentence — is not being perverse.
    var isBoardFolded = LoopWorkspaceRail.loadBoardFolded()
    /// Whether a rail width has ever been committed by a drag on this machine.
    ///
    /// What lets a board open the rail wider without ever overruling a width somebody
    /// chose. Read once at open rather than on every render — it only changes here, in
    /// `railWidthChanged`, and a `UserDefaults` read per body pass would be one per pointer
    /// event during a drag.
    var hasCustomRailWidth = LoopWorkspaceRail.hasStoredWidth()
    /// Whether the board has the workspace to itself. Deliberately *not* persisted: a cover
    /// over the terminal is a thing you open to look at something, and a window that
    /// relaunched with the terminal hidden behind a diagram would be a window that looked
    /// broken.
    var isBoardExpanded = false
    /// The newest beat that was on screen when this workspace was last left — what the
    /// rail's `SINCE YOU LOOKED` hairline is drawn against.
    ///
    /// Per window rather than on the node: "since *you* looked" is a fact about a person
    /// at a screen, and the daemon writing it would answer for every window at once.
    var seenBeatID: String?
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
    /// The workspace's last tab was closed. What that means is `AppFeature`'s to say:
    /// for a loop it is the end of the loop itself, put to the same "Delete Loop…"
    /// confirmation the sidebar's delete goes through — the loop may still be running,
    /// and ⌘W is not consent. For a quick chat it is just the terminal being put away;
    /// the chat outlives its session.
    case lastTabClosed
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
    /// A keypress on the agent pane's "Process exited. Press any key to close." screen —
    /// the human agreeing the loop is over. Declared here (the surface is this feature's
    /// to wire) and handled by `AppFeature`, which owns both the workspace's dismissal
    /// and the daemon connection the deletion goes out on.
    case primaryExitAcknowledged
    /// The loop bar's Stop loop and Show in graph, and the right rail's downstream rows.
    /// All three are `AppFeature`'s to carry out — stopping talks to the daemon, and both
    /// of the others change what the whole window is showing — so they are declared here
    /// and handled up there, the way `.nodeTapped` already is.
    /// ⌥G, and the toolbar's trailing panel toggle.
    case railToggled
    /// The rail's leading edge was dragged. Sent once, on release — a per-frame action
    /// would put a reducer run and a `UserDefaults` write behind every pixel.
    case railWidthChanged(CGFloat)
    /// The summary section's header row.
    case summaryFoldToggled
    /// The board section's header row.
    case boardFoldToggled
    /// The board section's expand button, and the cover's own close.
    case boardExpandToggled
    /// The amber block's `Answer it` — the question is in the terminal, so this is a
    /// request for the keyboard to go there.
    case summaryAnswerTapped
    /// This workspace stopped being the one on screen. The moment everything it was
    /// showing counts as seen — done on the way *out* so that coming back is what shows
    /// the hairline, which is the whole point of it.
    case workspaceLeft
    case stopLoopTapped
    case showInGraphTapped
    case railTargetTapped(UUID)
  }

  @Dependency(\.terminalLayoutStore) var terminalLayoutStore
  /// Closing a tab or a pane is the one thing that should still end a surface — and,
  /// since #254, the shell session behind it. Switching loops deliberately doesn't — see
  /// `TerminalSurfaceStore` — so without telling it here, a closed pane's terminal would
  /// linger until it aged out of the cache.
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
        guard let index = state.layout.tabs.index(id: id), let tab = state.layout.tabs[id: id]
        else { return .none }
        // The last tab going means the workspace has nothing left to show, which is the
        // end of the loop itself — `AppFeature`'s call, since the deletion is its job,
        // and it asks the human first. Nothing is torn down on the way out: the answer
        // may be no, and a tab whose terminals were already retired and whose shells
        // were already killed is not a tab anyone can be given back.
        guard state.layout.tabs.count > 1 else { return .send(.lastTabClosed) }
        terminalSurfaceClient.retire(tab.surfaces.map(\.id))
        // The shells in the tab die with it — a pane's zmx session is the pane's reason
        // for existing, and one left running after its pane is gone is invisible until
        // reboot (#254). The agent surface is exempt: its session belongs to the loop,
        // which outlives any pane and is ended by deleting the node, not by closing a
        // tab in front of it.
        terminalSurfaceClient.killSessions(
          tab.surfaces.filter { !$0.launchesClaudeCode }.map(\.id), state.projectPath)
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
        // The focused pane is the one that divides. Always splitting `primary` instead
        // would drop every new pane next to the first one, wherever you were actually
        // working.
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
        // A shell the human closed ends with its pane (#254) — whether it was closed by
        // the x, ⌘W, or its own process exiting. An agent pane is never killed here: the
        // loop's session is the loop's, and ends when the node does.
        if !paneOrder[closedIndex].launchesClaudeCode {
          terminalSurfaceClient.killSessions([surfaceID], state.projectPath)
        }
        tab.root = root
        if tab.focusedSurfaceID == surfaceID {
          // Where the keyboard lands, matching Ghostty: the pane before the one that
          // closed, or the new first pane if the one that
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

      case .railToggled:
        state.isRailVisible.toggle()
        LoopWorkspaceRail.saveVisible(state.isRailVisible)
        return .none

      case .railWidthChanged(let width):
        state.railWidth = LoopWorkspaceRail.clamped(width)
        LoopWorkspaceRail.saveWidth(state.railWidth)
        // From here on the width is theirs, and a board arriving never moves it again.
        state.hasCustomRailWidth = true
        return .none

      case .summaryFoldToggled:
        state.isSummaryFolded.toggle()
        LoopWorkspaceRail.saveSummaryFolded(state.isSummaryFolded)
        return .none

      case .boardFoldToggled:
        state.isBoardFolded.toggle()
        LoopWorkspaceRail.saveBoardFolded(state.isBoardFolded)
        return .none

      case .boardExpandToggled:
        state.isBoardExpanded.toggle()
        return .none

      case .summaryAnswerTapped:
        // The agent's own tab, and its own pane within it. A question was asked in that
        // terminal and answering it means typing there — anything else would be a second
        // place to answer from, which is the inbox the rail exists instead of.
        guard
          let tab = state.layout.tabs.first(where: {
            $0.surfaces.contains(where: \.launchesClaudeCode)
          })
        else { return .none }
        state.layout.selectedTabID = tab.id
        guard let surface = tab.surfaces.first(where: \.launchesClaudeCode) else { return .none }
        return .send(.paneFocused(tabID: tab.id, surfaceID: surface.id))

      case .workspaceLeft:
        state.seenBeatID = state.node.summary?.current?.id
        return .none

      case .stopLoopTapped, .showInGraphTapped, .railTargetTapped, .primaryExitAcknowledged,
        .lastTabClosed:
        // Handled by `AppFeature`'s parent `Reduce` — see the actions' own doc comment.
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
