/// The four loop primitives graphcode orchestrates — see docs/01-loop-taxonomy.md for
/// the full definitions — plus sketch, which is deliberately not a fifth kind: it is
/// the starting point before the work has a shape, and `SketchPromotion` is how it
/// becomes one of the four once it does.
///
/// Declared in the order a human should consider them, because that is the order
/// `allCases` walks and the order every picker shows. The axis is how much you have to
/// decide before the loop can start: sketch first, because it demands nothing at all —
/// it opens and you start working; then goal-based, since a loop that knows when it is
/// finished is what most work wants and the only kind that both starts itself and ends
/// itself; then time-based, which starts itself but never ends; then turn-based, which
/// does neither without a person; then composite, which is a graph rather than a
/// session and belongs at the end for that reason alone.
///
/// Raw values are unchanged by that ordering, so every graph already on disk decodes
/// exactly as before.
public enum LoopType: String, Codable, CaseIterable, Sendable {
  /// The zero-commitment type: no goal, no cadence, no checkpoint. A bare session that
  /// works with you until you promote it or close it.
  case sketch
  case goalBased
  case timeBased
  case turnBased
  /// Serialised as `proactive`, the name this type shipped under. Every graph written so
  /// far carries that string, and a daemon or CLI in `~/.graphcode/bin` can be a version
  /// behind the app that wrote it — so the on-disk word outlives the vocabulary change.
  case composite = "proactive"
}
