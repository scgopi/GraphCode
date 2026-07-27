/// The safety rail on an edge that closes a loop back to an ancestor — the
/// `maxIterations`/`until` guard docs/02-graph-of-loops.md describes and
/// docs/08-quality-and-token-budgets.md insists must be a load-bearing part of the
/// domain model rather than a convention someone remembers to follow.
///
/// **A guard is also the switch that makes a cycle run at all.** Without one, an edge
/// fires exactly once and a drawn cycle sits inert after one pass — the behaviour every
/// graph had through Phase 4. Attaching a guard is what opts an edge into re-firing, and
/// it can only do so with a bound attached. That ordering is deliberate: there is no way
/// to express "loop forever" by accident, because the feature that lets a loop repeat is
/// the same feature that bounds it.
public struct CycleGuard: Codable, Equatable, Sendable {
  /// How many times this edge may fire in total. `nil` means unbounded *by count* — only
  /// legal alongside an `until`, enforced by `isBounded`.
  public var maxIterations: Int?
  /// A shell command re-evaluated before each re-fire; once it exits 0 the cycle stops.
  /// The escape hatch for loops whose end is a condition rather than a count ("until the
  /// test suite is green").
  public var until: String?

  public init(maxIterations: Int? = nil, until: String? = nil) {
    self.maxIterations = maxIterations
    self.until = until
  }

  public var effectiveUntil: String? {
    guard let until else { return nil }
    let trimmed = until.trimmingCharacters(in: .whitespaces)
    return trimmed.isEmpty ? nil : trimmed
  }

  /// A guard with neither a count nor a condition bounds nothing, and would turn a cycle
  /// into an unattended infinite loop spending tokens forever. `GraphStore` refuses to
  /// attach one, which is the whole point of the type.
  public var isBounded: Bool {
    if let maxIterations { return maxIterations > 0 }
    return effectiveUntil != nil
  }

  /// Whether the edge may fire again, on count alone. The `until` half is asked
  /// separately because answering it means running a subprocess.
  public func allowsFiring(afterFireCount fireCount: Int) -> Bool {
    guard let maxIterations else { return true }
    return fireCount < maxIterations
  }

  public var summary: String {
    switch (maxIterations, effectiveUntil) {
    case (let max?, let until?): return "≤\(max)× or until `\(until)`"
    case (let max?, nil): return "≤\(max)×"
    case (nil, let until?): return "until `\(until)`"
    case (nil, nil): return "unbounded"
    }
  }
}
