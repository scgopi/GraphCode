import ComposableArchitecture
import Dependencies
import Foundation
import GraphcodeKit

/// What the lane chip and the context menus say about one folder's worktrees without
/// opening anything: `6 worktrees · 4 reclaimable`.
struct WorktreeFolderStats: Equatable, Sendable {
  var total = 0
  var reclaimable = 0
  var totalBytes: Int64 = 0
}

extension AppFeature {
  /// The worktree-hygiene half of the app's actions, nested so the whole surface costs
  /// `AppFeature.Action` a single case.
  @CasePathable
  enum Worktrees {
    /// Any of the four routes in — lane chip, either context menu, `File ▸ Worktrees…`.
    case sweepRequested(projectPath: String)
    case sweepDismissed
    case sweep(WorktreeSweepFeature.Action)
    case statsLoaded(projectPath: String, WorktreeFolderStats)
    case statsReloadRequested(projectPath: String)
    case settingsRequested(projectPath: String)
    case settingsDismissed
  }
}

/// One folder past its notice threshold — what the titlebar's worktree chip shows.
struct WorktreeNotice: Equatable {
  let projectPath: String
  let folderName: String
  let stats: WorktreeFolderStats
}

extension AppFeature.State {
  /// Folders past their own notice threshold, worst accumulation first. The titlebar
  /// chip shows the first and counts the rest — the same standing the needs-you chip
  /// has: absent whenever the answer is "nothing to mention".
  ///
  /// The policy arrives as a closure because it lives in `~/.graphcode/settings.json`
  /// (the view passes `SettingsModel`), and a computed property that read the disk
  /// per body pass would put a file hit on the render path.
  func worktreeNotices(
    policyFor: (String) -> WorktreeHygienePolicy
  ) -> [WorktreeNotice] {
    projects.compactMap { project -> WorktreeNotice? in
      guard let stats = worktreeStats[project.id] else { return nil }
      let policy = policyFor(project.id)
      guard stats.totalBytes >= policy.noticeSizeBytes || stats.total >= policy.noticeCount
      else { return nil }
      return WorktreeNotice(
        projectPath: project.id, folderName: project.graph.project.name, stats: stats)
    }
    .sorted { $0.stats.totalBytes > $1.stats.totalBytes }
  }
}

/// Per-folder policy reads, behind a dependency so the resolve-moment path is testable
/// without a settings file on disk.
struct WorktreePolicyClient: Sendable {
  var policy: @Sendable (_ projectPath: String) -> WorktreeHygienePolicy
}

extension WorktreePolicyClient: DependencyKey {
  static let liveValue = Self { path in
    GraphcodeSettingsStore.load().worktreePolicy(forProjectPath: path)
  }
  static let testValue = Self { _ in WorktreeHygienePolicy() }
}

extension DependencyValues {
  var worktreePolicyClient: WorktreePolicyClient {
    get { self[WorktreePolicyClient.self] }
    set { self[WorktreePolicyClient.self] = newValue }
  }
}

/// Worktree hygiene, at the level that can see every project: opening the sweeper from
/// any route, keeping the per-folder stats the chip and menus read, and acting on the
/// resolve moment — the one instant a worktree becomes garbage knowably.
///
/// Composed **before** `AppFeature`'s main `Reduce`, which is what lets the
/// `.graphChanged` handler read the *previous* graph out of state and diff it against
/// the broadcast — the main reducer replaces it on the same action a moment later.
struct AppWorktreesReducer: Reducer {
  typealias State = AppFeature.State
  typealias Action = AppFeature.Action

  @Dependency(\.gitClient) var gitClient
  @Dependency(\.worktreePolicyClient) var worktreePolicyClient

  var body: some Reducer<AppFeature.State, AppFeature.Action> {
    Reduce { state, action in
      switch action {
      case .worktrees(.sweepRequested(let path)):
        guard let project = state.projects[id: path], Self.tracksWorktrees(path)
        else { return .none }
        state.worktreeSweep = WorktreeSweepFeature.State(
          projectPath: path,
          projectName: project.graph.project.name,
          nodes: Array(project.graph.nodes))
        return .none

      case .worktrees(.sweepDismissed):
        let path = state.worktreeSweep?.projectPath
        state.worktreeSweep = nil
        guard let path else { return .none }
        return reloadStats(path, nodes: nodes(in: state, path))

      // A removal changed what is on disk; the chip must not keep claiming the old
      // count after the sheet closes.
      case .worktrees(.sweep(.removalFinished)):
        guard let path = state.worktreeSweep?.projectPath else { return .none }
        return reloadStats(path, nodes: nodes(in: state, path))

      case .worktrees(.statsLoaded(let path, let stats)):
        state.worktreeStats[path] = stats
        // Mirrored into the project's own state, so the canvas — which only holds a
        // project-scoped store — can put the count on its `Worktrees…` menu item.
        state.projects[id: path]?.worktreeStats = stats
        return .none

      case .worktrees(.statsReloadRequested(let path)):
        return reloadStats(path, nodes: nodes(in: state, path))

      case .worktrees(.settingsRequested(let path)):
        state.projectSettingsPath = path
        return .none

      case .worktrees(.settingsDismissed):
        state.projectSettingsPath = nil
        return .none

      case .worktrees:
        return .none

      case .daemonEvent(.graphChanged(let graph)):
        return graphChangedEffects(state, next: graph)

      // The project canvas's folder menu — same sheets the sidebar and lane routes
      // open, reached through project-scoped signal actions because the canvas holds
      // no app store.
      case .projects(.element(id: let path, action: .worktreeSweepTapped)):
        return .send(.worktrees(.sweepRequested(projectPath: path)))

      case .projects(.element(id: let path, action: .projectSettingsTapped)):
        return .send(.worktrees(.settingsRequested(projectPath: path)))

      // The card's Reclaim: the project scope already cleared its offer on this same
      // action; actually removing the worktree needs `GitClient`, which is this level's.
      case .projects(.element(id: let path, action: .reclaimWorktreeTapped(let nodeID))):
        guard let node = state.projects[id: path]?.graph.nodes[id: nodeID],
          let ref = node.worktreeBinding
        else { return .none }
        return .run { send in
          try? await gitClient.removeWorktreeAndBranch(ref, false)
          await send(.worktrees(.statsReloadRequested(projectPath: path)))
        }

      default:
        return .none
      }
    }
  }

  /// The global graph is not a folder and a remote project's worktrees live on another
  /// machine — neither has anything local to sweep.
  static func tracksWorktrees(_ path: String) -> Bool {
    path != LoopGraphScope.globalPath && RemoteProjectLocation.parse(projectPath: path) == nil
  }

  /// `.git` is a directory in a primary checkout and a file in a linked worktree —
  /// either means git has something to say about this folder. Checked before any
  /// broadcast-driven git call so a plain folder never spawns `git` processes.
  private static func isGitRepository(_ path: String) -> Bool {
    FileManager.default.fileExists(
      atPath: (path as NSString).appendingPathComponent(".git"))
  }

  private func nodes(in state: AppFeature.State, _ path: String) -> [LoopNode] {
    Array(state.projects[id: path]?.graph.nodes ?? [])
  }

  /// What one broadcast means for hygiene: a project appearing or its binding set
  /// changing refreshes the stats, and a loop crossing into resolution is the resolve
  /// moment — assessed, then removed or offered per the folder's policy.
  private func graphChangedEffects(
    _ state: AppFeature.State, next graph: LoopGraph
  ) -> Effect<AppFeature.Action> {
    let path = graph.project.path
    guard Self.tracksWorktrees(path), Self.isGitRepository(path) else { return .none }
    let previous = state.projects[id: path]?.graph
    let nodes = Array(graph.nodes)

    let newlyResolved = nodes.filter { node in
      node.isResolved && node.worktreeBinding != nil
        && previous?.nodes[id: node.id].map { !$0.isResolved } == true
    }
    let bindingsChanged =
      Set((previous?.nodes ?? []).compactMap(\.worktreeBinding?.worktreePath))
      != Set(nodes.compactMap(\.worktreeBinding?.worktreePath))

    var effects: [Effect<AppFeature.Action>] = []
    if previous == nil || bindingsChanged || !newlyResolved.isEmpty {
      effects.append(reloadStats(path, nodes: nodes))
    }
    for node in newlyResolved {
      effects.append(resolveMoment(for: node, path: path, nodes: nodes))
    }
    return effects.isEmpty ? .none : .merge(effects)
  }

  private func reloadStats(_ path: String, nodes: [LoopNode]) -> Effect<AppFeature.Action> {
    .run { send in
      guard let inspections = try? await gitClient.inspectWorktrees(path) else { return }
      let assessments = WorktreeSweepFeature.assessments(inspections, nodes: nodes)
      let stats = WorktreeFolderStats(
        total: assessments.count,
        reclaimable: assessments.filter { $0.tier == .safeToRemove }.count,
        totalBytes: assessments.compactMap(\.facts.sizeBytes).reduce(0, +))
      await send(.worktrees(.statsLoaded(projectPath: path, stats)))
    }
  }

  /// The good moment: the loop just resolved and the human still remembers what its
  /// worktree was. The loop's own binding is excluded from the assessment — it is the
  /// thing being reclaimed, not a reason to keep the worktree — but any *other* loop
  /// still pointing there keeps the worktree out of the safe tier, and automatic
  /// removal never touches anything but the safe tier regardless of the policy.
  private func resolveMoment(
    for node: LoopNode, path: String, nodes: [LoopNode]
  ) -> Effect<AppFeature.Action> {
    guard let ref = node.worktreeBinding else { return .none }
    let policy = worktreePolicyClient.policy(path)
    guard policy.onResolveLanded != .keep else { return .none }
    let others = nodes.filter { $0.id != node.id }
    let title = node.title
    let nodeID = node.id
    return .run { send in
      guard let inspections = try? await gitClient.inspectWorktrees(path),
        let inspection = inspections.first(where: { $0.ref.worktreePath == ref.worktreePath })
      else { return }
      let assessment = WorktreeAssessment(
        ref: inspection.ref,
        facts: inspection.facts,
        binding: WorktreeAssessment.binding(
          forWorktreePath: ref.worktreePath, in: others),
        loopTitle: title)
      guard assessment.tier == .safeToRemove else { return }
      switch policy.onResolveLanded {
      case .remove:
        try? await gitClient.removeWorktreeAndBranch(inspection.ref, inspection.facts.prunable)
        await send(.worktrees(.statsReloadRequested(projectPath: path)))
      case .ask:
        await send(
          .projects(
            .element(
              id: path,
              action: .worktreeReclaimOffered(nodeID: nodeID, assessment: assessment))))
      case .keep:
        break
      }
    }
  }
}
