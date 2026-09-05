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
    guard node.state == .running || node.state == .idle || node.state == .waiting
    else { return .targetNotLive }
    return nil
  }

  /// What a stop request types into a loop's session (`GraphStore.stopNode`). Stopping
  /// is a message now rather than a kill: only the loop itself can cancel the cadence it
  /// set up — a `/loop`, a scheduled wakeup, a cron entry — and killing the PTY left
  /// every one of those running against a loop the graph considered stopped.
  ///
  /// Phrased as an instruction rather than a command string because the command differs
  /// per backend and per looping skill, while "stop looping, don't schedule another
  /// pass" is understood by all of them.
  ///
  /// It says *stop*, never "end" or "finish": to an agent those read as instructions to
  /// exit the session, which is the very thing this replaced.
  public static let stopRequest =
    "[graphcode] Stop requested from the graph. Stop this loop now: turn off any "
    + "recurring schedule you set up for it — a /loop, a scheduled wakeup, a cron entry "
    + "— and do not start another pass. Stop where you are, say where you got to, and "
    + "stay in the session: the loop is what stops, not you. Do not exit or quit."

  /// The stop request a blown token budget sends (`GraphStore.evaluateGoal`). Same
  /// instruction as `stopRequest` — only the loop can cancel its own cadence — prefixed
  /// with the *why*, because "stop" with no reason reads as a human's change of mind
  /// and this one is arithmetic the loop can verify against its own usage.
  public static func budgetExhaustedRequest(used: Int, budget: Int) -> String {
    "[graphcode] Token budget exhausted: this loop has spent \(used) of its "
      + "\(budget)-token budget. Stop this loop now: turn off any recurring schedule "
      + "you set up for it — a /loop, a scheduled wakeup, a cron entry — and do not "
      + "start another pass. Stop where you are, say where you got to, and stay in the "
      + "session: the loop is what stops, not you. Do not exit or quit."
  }

  /// Typed into a goal loop's still-live session the moment it resolves successfully —
  /// the one moment the method that worked is fully in context and the loop has nothing
  /// left to do with it. The ask is to write into the *backend's* native skill format
  /// inside the project (agents write to the project all the time; graphcode itself
  /// never does), so the next loop's backend picks it up with no graphcode runtime in
  /// between: the graph curates, the backend executes.
  ///
  /// "If" is load-bearing: a one-off fix distilled into a skill is library pollution,
  /// and the judgement of reusability belongs to the agent that did the work.
  public static let distillSkillRequest = prefix + distillSkillBody

  private static let prefix = "[graphcode] "

  private static let distillSkillBody =
    "Goal met. Before you finish: if the method that got you here would be "
    + "reusable by another loop in this project, distill it into a project skill in "
    + "your backend's native format (for Claude Code: .claude/skills/<name>/SKILL.md, "
    + "a short markdown recipe with a one-line description). If it was one-off work, "
    + "skip this."

  /// The Mailroom's half of the same moment, and the board's only *pull*.
  ///
  /// Every other mailroom affordance is read-side — the briefing teaches the verbs,
  /// the digest and the status line remind a loop to look. Nothing asked anyone to
  /// write, and a board nobody writes to carries nothing to the loops that come after.
  /// Resolution is when a loop knows what it learned and has no further use for it.
  ///
  /// Unlike the skill ask this fires on failure too, and for every loop type: a dead
  /// end is the single most valuable thing on a board, because it is the one finding
  /// a successor would otherwise pay for twice.
  private static func mailroomPostBody(projectPath: String) -> String {
    "Before you finish: if you learned something a peer or a successor should not have "
      + "to rediscover — a dead end, a decision, a claim you staked — leave it on the "
      + "board with: graphcode mail post \(projectPath) [--topic <t>] <note…>. "
      + "One note, not a transcript. If there is nothing worth a peer's time, skip this."
  }

  /// The words for a session whose loop has just resolved, or `nil` when it is owed
  /// none. Assembled rather than queued separately so a goal loop that both succeeded
  /// and has a board to post to is interrupted once, not twice.
  public static func resolutionAsk(
    distillSkill: Bool, mailroomProjectPath: String?
  ) -> String? {
    var parts: [String] = []
    if distillSkill { parts.append(distillSkillBody) }
    if let path = mailroomProjectPath { parts.append(mailroomPostBody(projectPath: path)) }
    guard !parts.isEmpty else { return nil }
    return prefix + parts.joined(separator: " ")
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
