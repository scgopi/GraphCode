import ComposableArchitecture
import Foundation
import GraphcodeKit

/// One `LoopNode`'s terminal + turn-based check. The terminal itself is a real
/// `GhosttyKit` surface (see `GhosttyTerminalView`) — Ghostty owns the PTY and child
/// process directly (usually a `zmx attach` wrapper), so this reducer only tracks
/// whether that process has exited, not any scrollback or session handle. The check is
/// still a human decision via the Approve/Reject bar (see docs/07-roadmap.md).
@Reducer
struct LoopNodeDetailFeature {
  @ObservableState
  struct State: Equatable, Identifiable {
    var node: LoopNode

    var id: UUID { node.id }
  }

  enum Action {
    case processExited(succeeded: Bool)
    case checkApproved
    case checkRejected
  }

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .processExited(let succeeded):
        state.node.state = succeeded ? .succeeded : .failed
        return .none

      // The check is a human decision, not a computed one. Approve/reject just labels
      // the node locally — `GraphCanvasFeature` is what actually tells `graphcoded`
      // about the resolution (see its `.detail(.checkApproved)`/`.detail(.checkRejected)`
      // handling), which is what triggers automatic outgoing-edge firing.
      case .checkApproved:
        state.node.state = .succeeded
        return .none

      case .checkRejected:
        state.node.state = .failed
        return .none
      }
    }
  }
}
