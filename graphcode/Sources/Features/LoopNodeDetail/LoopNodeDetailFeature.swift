import ComposableArchitecture
import Foundation

/// One `LoopNode`'s terminal + turn-based check, per Phase 1 scope (see
/// docs/07-roadmap.md#phase-1--single-loop-manual-check): a single node, no
/// `LoopEdge`/`LoopGraph`, check performed by a human via the Approve/Reject bar —
/// nothing here is automated yet.
@Reducer
struct LoopNodeDetailFeature {
  @ObservableState
  struct State: Equatable {
    var node: LoopNode
    var scrollback = ""
    var sessionID: UUID?
    var launchError: String?
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

      // Phase 1's whole point: the check is a human decision, not a computed one.
      // Approve/reject just labels the node — nothing downstream reacts to it yet,
      // since there's no graph/orchestrator to hand off to until Phase 2/3.
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
