import ComposableArchitecture
import Foundation
import GraphcodeKit

/// ⌥⌘← / ⌥⌘→ — where this human has actually been, as opposed to what sits next to what.
///
/// `selectNextLoop`/`selectPreviousLoop` walk sidebar order, which answers "what is
/// beside this loop". Clicking A, then P in another project, then Q answers a different
/// question entirely, and until now nothing in the app could retrace it. This is that
/// second answer: a browser's back/forward stack, with the same truncation rule.
///
/// Kept out of `AppFeature.swift` because that type is at swiftlint's body-length limit,
/// and because the recording rule reads better next to the walking rule than a hundred
/// lines from it.
extension AppFeature {
  /// Opens what a history step landed on, *without* recording it.
  ///
  /// This is the whole reason back/forward doesn't go through `.nodeTapped`: that action
  /// records, and a Back that recorded would append the place it just came from, so the
  /// next Back would return there and the stack would oscillate between two loops
  /// forever. Two entry points, one of which records, is clearer than a flag saying
  /// "don't record this one" that every future caller has to remember to set.
  var historyReducer: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      // The predicate closes over a snapshot taken before `&state` is borrowed —
      // building it inside the call would be two overlapping accesses to the same
      // variable, one of them exclusive.
      case .historyBackTapped:
        let isResolvable = canResolve(state)
        return step(&state) { $0.back(where: isResolvable) }

      case .historyForwardTapped:
        let isResolvable = canResolve(state)
        return step(&state) { $0.forward(where: isResolvable) }

      default:
        return .none
      }
    }
  }

  private func step(
    _ state: inout State, _ move: (inout LoopHistory) -> LoopVisit?
  ) -> Effect<Action> {
    var history = state.loopHistory
    guard let visit = move(&history) else { return .none }
    state.loopHistory = history
    loopHistoryStore.save(history)
    switch visit {
    case .loop(let projectPath, let nodeID):
      openLoopWithoutRecording(&state, projectPath: projectPath, nodeID: nodeID)
    case .quickChat(let id):
      guard let chat = state.quickChats[id: id] else { return .none }
      openQuickChat(chat, &state)
    }
    return .none
  }

  /// Whether a remembered visit can still be opened *right now*. A closed project or a
  /// deleted loop makes an entry unreachable rather than wrong, so the walk steps over
  /// it and the entry stays in the file — the project may well be open again next
  /// launch, and a history that erased itself on a transient miss would be worse than
  /// no history.
  ///
  /// The blocked-node rule is the one `.nodeTapped` applies
  /// (`LoopNode.opensOnHumanTap`); the two differ only in what they do when it fails —
  /// a tap on a gated loop raises the notice alert, a Back onto one keeps walking.
  private func canResolve(_ state: State) -> (LoopVisit) -> Bool {
    { visit in
      switch visit {
      case .loop(let projectPath, let nodeID):
        guard let node = state.projects[id: projectPath]?.graph.nodes[id: nodeID] else {
          return false
        }
        return node.opensOnHumanTap
      case .quickChat(let id):
        return state.quickChats[id: id] != nil
      }
    }
  }

  private func openLoopWithoutRecording(
    _ state: inout State, projectPath: String, nodeID: UUID
  ) {
    guard let project = state.projects[id: projectPath],
      let node = project.graph.nodes[id: nodeID]
    else { return }
    let layout = terminalLayoutStore.load(forNode: nodeID) ?? .defaultLayout(forNode: nodeID)
    state.openLoop = LoopWorkspaceFeature.State(
      node: node,
      graph: project.graph,
      layout: layout,
      projectPath: projectPath,
      projectName: project.graph.project.name)
    state.openLoop?.seenArtifactoryPostID =
      LoopWorkspaceRail.loadSeenArtifactoryPost(forProjectPath: projectPath)
    state.selectedProjectPath = projectPath
  }

  /// Records an arrival the human chose. Called from the two places a workspace opens on
  /// purpose — a loop tap and a quick chat tap — and from neither of the history steps.
  func recordVisit(_ visit: LoopVisit, _ state: inout State) {
    state.loopHistory.record(visit)
    loopHistoryStore.save(state.loopHistory)
  }
}
