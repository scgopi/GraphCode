import Foundation

/// A folder (or repository) graphcode has opened as a project — see
/// docs/02-graph-of-loops.md#loopgraph. `path` is the canonicalized absolute
/// filesystem path and is the stable identity: it's what a `LoopGraph`'s persisted
/// file on disk is keyed by, and what the welcome screen's recent-projects list
/// de-duplicates on.
///
/// This is the first concrete piece of the `LoopGraphScope.project(ProjectRef)` the
/// docs have described since Phase 2 — there is still no `.global` Orchestrator Graph
/// and no `LoopGraphScope` enum, since every graph today is implicitly project-scoped
/// (see `LoopGraph`'s doc comment).
public struct ProjectRef: Identifiable, Codable, Equatable, Sendable {
  public var path: String
  public var name: String
  public var lastOpenedAt: Date

  public var id: String { path }

  public init(path: String, name: String, lastOpenedAt: Date = Date()) {
    self.path = path
    self.name = name
    self.lastOpenedAt = lastOpenedAt
  }
}
