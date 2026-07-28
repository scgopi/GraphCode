/// The four loop primitives graphcode orchestrates — see docs/01-loop-taxonomy.md for
/// the full definitions.
///
/// Declared in the order a human should consider them, because that is the order
/// `allCases` walks and the order every picker shows: goal-based first, since a loop that
/// knows when it is finished is what most work wants and the only kind that both starts
/// itself and ends itself; then time-based, which starts itself but never ends; then
/// turn-based, which does neither without a person; then proactive, which is a graph
/// rather than a session and belongs at the end for that reason alone.
///
/// Raw values are unchanged by that ordering, so every graph already on disk decodes
/// exactly as before.
public enum LoopType: String, Codable, CaseIterable, Sendable {
  case goalBased
  case timeBased
  case turnBased
  case proactive
}
