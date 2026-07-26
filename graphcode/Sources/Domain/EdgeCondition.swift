/// When an edge is allowed to fire — see docs/02-graph-of-loops.md#loopedge`. Phase 2
/// has no automatic condition evaluation (a human marks an edge fired directly,
/// regardless of `condition`), so this is descriptive only for now; the orchestrator
/// starts actually evaluating it in Phase 3. The cycle-guard cases the full taxonomy
/// describes (`.maxIterations`, `.until`) are deferred until there's an orchestrator to
/// enforce them — declaring them earlier would be misleading.
enum EdgeCondition: String, Codable, CaseIterable, Sendable {
  case always
  case onSuccess
  case onFailure
}
