/// Where a proactive node is in the pilot-before-arm flow —
/// docs/08-quality-and-token-budgets.md#managing-token-usage and
/// docs/06-ux-terminals.md#pilot--dry-run-before-arming-a-proactive-routine.
///
/// The article's point is that dynamic workflows can spawn hundreds of agents, so the
/// cheap check should be the path of least resistance rather than the one you have to
/// remember to take. That's why this is a state on the node and not a button somewhere:
/// a proactive node *cannot* be armed from `.notPiloted`, so the dry run isn't skippable
/// by forgetting it.
public enum PilotState: String, Codable, Equatable, Sendable {
  /// Created but never run. Cannot be armed from here — that's the whole mechanism.
  case notPiloted
  /// A dry run is in flight against a single slice.
  case piloting
  /// The dry run finished. Its result is what a human arms (or doesn't) on.
  case piloted
  /// Live against its real trigger.
  case armed

  public var displayName: String {
    switch self {
    case .notPiloted: return "Not piloted"
    case .piloting: return "Piloting"
    case .piloted: return "Piloted"
    case .armed: return "Armed"
    }
  }

  /// Arming is only legal straight after a pilot. Re-arming an already-armed node is a
  /// no-op rather than an error; arming one that has never run is refused.
  public var canArm: Bool { self == .piloted }
}
