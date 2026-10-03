import ComposableArchitecture
import Foundation
import GraphcodeKit

/// Nod's graph layer, carried out where the loop's node, its graph and the daemon
/// connection meet: the chat's delegates, and the cards `NodGraphSlots` draws into it.
extension LoopWorkspaceFeature {
  func nodChatDelegate(_ state: inout State, _ delegate: NodChatFeature.Action.Delegate)
    -> Effect<Action>
  {
    let node = state.node
    let graph = state.graph
    switch delegate {
    case .openInShellTab(let command):
      return openInShellTab(&state, command: command)

    case .forkAsSibling(let messageID):
      let conversationID = state.nodChat?.transcript.session?.conversationID
      return nodGraphEffect(state) { send in
        _ = try await nodGraphActions.fork(node, graph, messageID, conversationID, send)
      }

    case .runPlanAsComposite(let planID):
      guard let plan = editablePlan(planID, in: state) else { return .none }
      return nodGraphEffect(state) { send in
        _ = try await nodGraphActions.runAsComposite(plan, node, send)
      }

    case .graphCommand(let name, let argument):
      switch NodGraphVerb.parse("/\(name) \(argument)") {
      case .failure(.usage(let usage)):
        return .send(.nodGraphActionFailed("Usage: \(usage)"))
      case .failure(.notAGraphVerb):
        return .none
      case .success(let verb):
        switch verb.commands(from: node.id, in: graph) {
        case .failure(let error):
          return .send(.nodGraphActionFailed(error.message))
        case .success(let commands):
          return nodGraphEffect(state) { send in
            for command in commands { try await send(command) }
          }
        }
      }

    case .messageLoop(let id):
      guard let target = graph.nodesAtAnyDepth.first(where: { $0.id == id }) else {
        return .none
      }
      state.nodChat?.draft = "/ask @\(target.title) "
      return .none

    case .editGoal:
      state.nodGoalDraft = node.goal?.summary ?? state.nodChat?.goal ?? ""
      return .none

    case .signIn, .raiseSpendCap:
      return .run { _ in await nodSettings.openNodSettings() }

    case .editPolicyChosen(let policy):
      state.nodChat?.editPolicy = policy
      return .run { _ in await nodSettings.setEditPolicy(policy) }

    case .runtimeNeeded:
      return requestNodSession(state)
    }
  }

  /// Asks graphcoded for this loop's session: resumed if it ended, started if it never ran.
  /// A no-op while one is alive, so opening the pane can ask unconditionally.
  func requestNodSession(_ state: State) -> Effect<Action> {
    let nodeID = state.node.id
    return nodGraphEffect(state) { send in try await send(.resumeSession(nodeID)) }
  }

  func nodGraphLayer(_ state: inout State, _ action: Action) -> Effect<Action> {
    switch action {
    case .nodPlanEdited(let plan):
      state.nodPlanEdits[plan.planID] = plan
      return .none

    case .nodHandoffTapped(let offer, let brief, let turn):
      state.nodSettledHandoffs.insert(turn)
      let commands = offer.commands(brief: brief)
      return nodGraphEffect(state) { send in
        for command in commands { try await send(command) }
      }

    case .nodHandoffDismissed(let turn):
      state.nodSettledHandoffs.insert(turn)
      return .none

    case .nodMailAnswered(let mail, let text):
      guard let command = mail.answerCommand(from: state.node.id, text: text) else {
        return .none
      }
      return nodGraphEffect(state) { send in try await send(command) }

    case .nodGoalDraftChanged(let draft):
      state.nodGoalDraft = draft
      return .none

    case .nodGoalSaved:
      let summary = (state.nodGoalDraft ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      guard !summary.isEmpty else { return .none }
      state.nodGoalDraft = nil
      let command = GraphCommand.updateNode(state.node.id, update: NodeUpdate(goalSummary: summary))
      return nodGraphEffect(state) { send in try await send(command) }

    case .nodGraphActionFailed(let message):
      state.nodChat?.sendError = message
      return .none

    default:
      return .none
    }
  }

  /// The plan card's edited copy when there is one, else the plan as Nod proposed it.
  func editablePlan(_ planID: String, in state: State) -> NodEditablePlan? {
    state.nodPlanEdits[planID]
      ?? state.nodChat?.transcript.plan(id: planID).map(NodEditablePlan.init)
  }

  /// Runs `body` with the app's daemon connection as its `GraphCommand` sender; a throw
  /// lands in the chat's error line.
  private func nodGraphEffect(
    _ state: State, _ body: @escaping @Sendable (NodGraphActions.Send) async throws -> Void
  ) -> Effect<Action> {
    let projectPath = state.projectPath
    let orchestratorClient = orchestratorClient
    return .run { send in
      do {
        try await body { command in
          try await orchestratorClient.send(
            .graphCommand(projectPath: projectPath, command: command))
        }
      } catch {
        await send(.nodGraphActionFailed(error.localizedDescription))
      }
    }
  }
}
