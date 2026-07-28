import Foundation

/// Whether a graph belongs to a project or is *the* always-resident Orchestrator Graph —
/// docs/02-graph-of-loops.md#the-orchestrator-graph--global-vs-project-scope.
///
/// The global graph is where triggers that aren't scoped to any one repo live (watch an
/// inbox, a channel, a calendar). It dispatches what it finds into a project's graph
/// through a cross-graph `.spawn` edge, so every project doesn't have to grow its own
/// bespoke "watch an external thing" plumbing.
public enum LoopGraphScope: Equatable, Sendable {
  case global
  case project(ProjectRef)

  /// The global graph is keyed by a reserved path rather than a real folder. Doing it
  /// this way means `ProjectPersistence`, `ProjectRegistry`'s routing, and every
  /// `graph.project.path` call site keep working unchanged — the alternative was
  /// threading an either-or through all of them for the sake of one extra graph.
  ///
  /// A `graphcode://` URL, not a filesystem path, so it can never collide with a folder
  /// a human actually opens.
  public static let globalPath = "graphcode://global"

  public init(projectPath: String, name: String) {
    self =
      projectPath == Self.globalPath
      ? .global
      : .project(ProjectRef(path: projectPath, name: name))
  }

  /// A `ProjectRef` for either case, so existing code that reaches for `graph.project`
  /// doesn't have to care which it's holding.
  public var projectRef: ProjectRef {
    switch self {
    case .global:
      // "Graph", not "Orchestrator": in the sidebar this row sits above every folder and
      // its canvas is the whole workspace drawn as one graph (see `GraphOverview`), so
      // the name has to say what you get when you click it. "Orchestrator" named the
      // daemon-side machinery instead — a component nobody clicking a sidebar row is
      // looking for.
      return ProjectRef(path: Self.globalPath, name: "Graph")
    case .project(let ref):
      return ref
    }
  }

  public var isGlobal: Bool { self == .global }
}
