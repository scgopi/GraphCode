import Foundation

/// Delivery for `.message`-kind edges — docs/02-graph-of-loops.md#inter-loop-messaging-in-practice
/// and docs/05-orchestrator.md#cross-loop-messaging.
///
/// The transport is the backend's own `sendInput`, which for Claude Code is `zmx send`
/// into the very session a human can open. That shared session identity is the point: a
/// message from one loop lands in the terminal you can watch, not in a side channel.
///
/// **The orchestrator decides whether a message may be delivered at all**, and that
/// judgement lives here rather than at the call site. docs/05 puts it well: you wouldn't
/// want two people typing into one terminal at once. A node mid-check is exactly that
/// situation, and injecting into it would interleave with whatever a human is being
/// asked.
public enum MessageBus {
  public enum DeliveryFailure: Equatable, Sendable {
    /// The target isn't running, so there is no session to type into. A `.message` edge
    /// is for peers that are both live; it is not a way to start something.
    case targetNotLive
    /// The target is mid-turn — delivering now would interleave with a human.
    case targetBusyWithACheck
    /// The backend can't accept input mid-session, so it can never be a `.message`
    /// target (docs/04-cli-backends.md).
    case backendCannotAcceptInput
    /// The transport tried and failed.
    case transportFailed
    case emptyMessage
  }

  /// Whether a message may be injected into this node right now, or why not. Pure, so
  /// the same rule can be shown in the UI as an explanation and enforced at delivery
  /// without two definitions drifting apart.
  public static func deliverability(to node: LoopNode) -> DeliveryFailure? {
    guard node.backend.capabilities.supportsMidSessionInput else {
      return .backendCannotAcceptInput
    }
    if node.state == .awaitingInput { return .targetBusyWithACheck }
    guard node.state == .running || node.state == .idle else { return .targetNotLive }
    return nil
  }

  /// What actually gets typed into the target. The edge's transform decides the content;
  /// a `.script` transform runs to produce it, which is docs/08's "a script is cheaper
  /// than reasoning through the steps every time" applied to a hand-off.
  public static func messageText(
    for edge: LoopEdge,
    from source: LoopNode,
    runScript: (@Sendable (ShellPredicate) async -> String?)? = nil
  ) async -> String? {
    switch edge.payloadTransform {
    case .none:
      // Still worth sending: the fact that the upstream finished is itself the message.
      return "[graphcode] \(source.title) finished."
    case .template(let text):
      return text.isEmpty ? nil : "[graphcode] \(source.title): \(text)"
    case .script(let command):
      guard let runScript else { return nil }
      let output = await runScript(
        ShellPredicate(
          command: command, workingDirectory: source.worktreeBinding?.worktreePath))
      guard let output, !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { return nil }
      return "[graphcode] \(source.title): \(output)"
    }
  }
}
