import Foundation

/// The shape a sketch takes when it turns out to matter — the reason the type is worth
/// having. A sketch that produced something real must not have to be re-created: keep
/// the session, add a shape.
///
/// Each case carries **exactly one decision** — the thing the target type needs and a
/// sketch never asked for. Never a re-brief: the transcript so far is the loop's
/// context, and a promoted goal loop starts already knowing what was found.
///
/// Promotion is one-way by construction. There is no case that lands on `.sketch`, so
/// demotion — which would silently drop a done check or a cadence — is unrepresentable
/// rather than merely refused.
public enum SketchPromotion: Codable, Equatable, Sendable {
  /// Goal asks for a done check: what done looks like, in the promoter's words.
  case goal(GoalSpec)
  /// Turn asks where to pause: after every turn, or only before writes.
  case turn(pausesBeforeWritesOnly: Bool)
  /// Timed asks for a cadence, carried the way every time-based loop carries one — a
  /// `/loop` directive the session runs on itself (`LoopNode.triggerPrompt`).
  case timed(triggerPrompt: String)

  /// The `LoopType` this promotion lands on.
  public var targetType: LoopType {
    switch self {
    case .goal: .goalBased
    case .turn: .turnBased
    case .timed: .timeBased
    }
  }
}
