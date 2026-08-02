import ComposableArchitecture
import Foundation
import GraphcodeKit

/// ⌘K's slice of the root feature — the palette's query, its highlight, and what Return
/// does with them.
///
/// Split out of `AppFeature` for the reason `AppFeature+QuickChats.swift` is: it shares
/// none of that reducer's subject matter — no daemon, no project lifecycle — but it does
/// share its state, since jumping to a loop is the same `.nodeTapped` a sidebar row
/// sends. A slice over the same `State` and `Action`, not a feature with its own store.
///
/// The ranking itself is in `JumpPalette`, away from the store, where it can be checked
/// a keystroke at a time.
extension AppFeature {
  var jumpPaletteReducer: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .jumpPaletteRequested:
        // Always from empty. Reopening on the last search is a palette telling you what
        // you were looking for a minute ago rather than asking what you want now.
        state.jumpQuery = ""
        state.jumpSelection = 0
        state.isJumpPresented = true
        return .none

      case .jumpPaletteDismissed:
        state.isJumpPresented = false
        return .none

      case .jumpQueryChanged(let query):
        state.jumpQuery = query
        // Back to the top: the highlight belongs on the best match for what is typed
        // *now*, and holding an index across a changed list points it at a stranger.
        state.jumpSelection = 0
        return .none

      case .jumpSelectionMoved(let offset):
        let count = state.jumpResults.count
        guard count > 0 else { return .none }
        state.jumpSelection = ((state.jumpSelection + offset) % count + count) % count
        return .none

      case .jumpItemSelected(let result):
        state.isJumpPresented = false
        return .send(
          .projects(.element(id: result.projectPath, action: .nodeTapped(result.nodeID))))

      default:
        return .none
      }
    }
  }
}

extension AppFeature.State {
  /// What the palette is showing, ranked — see `JumpPalette`. Derived, like every other
  /// list in this state, so it can't drift from the graphs it searches.
  var jumpResults: [JumpPalette.Result] {
    JumpPalette.results(
      query: jumpQuery,
      graphs: projects.map { (graph: $0.graph, path: $0.id) },
      attention: Set(attentionItems.map(\.nodeID)))
  }
}
