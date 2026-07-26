/// The four loop primitives graphcode orchestrates — see docs/01-loop-taxonomy.md for
/// the full definitions. Phase 3 wires up `.turnBased` (human check) and `.timeBased`
/// (`graphcoded`-armed interval trigger); `.goalBased`/`.proactive` exist because the
/// taxonomy itself is fixed vocabulary, not because they're usable yet (see
/// docs/07-roadmap.md).
public enum LoopType: String, Codable, CaseIterable, Sendable {
  case turnBased
  case goalBased
  case timeBased
  case proactive
}
