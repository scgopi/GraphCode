import ComposableArchitecture
import Foundation

/// One `LoopNode`'s terminal + turn-based check. Originally the whole of Phase 1's
/// single-node slice; from Phase 2 on it's the detail sheet `GraphCanvasFeature` opens
/// for a node. Still no automation — the check is a human decision via the
/// Approve/Reject bar (see docs/07-roadmap.md).
@Reducer
struct LoopNodeDetailFeature {
  @ObservableState
  struct State: Equatable, Identifiable {
    var node: LoopNode
    var scrollback = ""
    var sessionID: UUID?
    var launchError: String?

    var id: UUID { node.id }
  }

  enum Action {
    case onAppear
    case sessionStarted(UUID)
    case sessionEvent(CLISessionEvent)
    case launchFailed(String)
    case inputSubmitted(String)
    case checkApproved
    case checkRejected
  }

  private enum CancelID { case session }

  @Dependency(\.cliSessionClient) var cliSessionClient

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .onAppear:
        guard state.sessionID == nil else { return .none }
        return .run { [node = state.node] send in
          do {
            let handle = try await cliSessionClient.launch(node)
            await send(.sessionStarted(handle.id))
            for await event in handle.events {
              await send(.sessionEvent(event))
            }
          } catch {
            await send(.launchFailed(String(describing: error)))
          }
        }
        .cancellable(id: CancelID.session)

      case .sessionStarted(let id):
        state.sessionID = id
        return .none

      case .sessionEvent(let event):
        switch event {
        case .output(let text):
          state.scrollback += text
        case .stateChanged(let newState):
          state.node.state = newState
        }
        return .none

      case .launchFailed(let message):
        state.launchError = message
        state.node.state = .failed
        return .none

      case .inputSubmitted(let text):
        guard let sessionID = state.sessionID else { return .none }
        return .run { _ in
          try? await cliSessionClient.sendInput(sessionID, text)
        }

      // The check is a human decision, not a computed one. Approve/reject just labels
      // the node — it doesn't fire any outgoing edges itself. Handing off to whatever
      // the node connects to is a separate, explicit action on the edge
      // (`GraphCanvasFeature.Action.edgeFireTapped`) until there's an orchestrator to
      // automate that in Phase 3.
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
