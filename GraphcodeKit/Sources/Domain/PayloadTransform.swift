/// How a `LoopEdge`'s source output becomes its target's input — see
/// docs/02-graph-of-loops.md#payloadtransform.
///
/// Deliberately an inspectable value rather than an opaque closure, so the canvas can
/// show *what* an edge hands off, not just *that* it hands something off. `.script` is
/// the concrete form of docs/08-quality-and-token-budgets.md's "use scripts for
/// deterministic work" principle: when the transform is mechanical, an edge should be
/// able to shell out instead of paying a model to re-derive the same steps every time.
public enum PayloadTransform: Codable, Equatable, Sendable {
  /// Hand off nothing — the target starts from its own prompt alone.
  case none
  /// Free text describing (or templating) what carries across.
  case template(String)
  /// A literal command run to produce the target's input.
  case script(String)

  /// One-line summary for the canvas/edge inspector.
  public var summary: String? {
    switch self {
    case .none: return nil
    case .template(let text): return text.isEmpty ? nil : text
    case .script(let command): return command.isEmpty ? nil : "$ \(command)"
    }
  }
}
