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

/// One removal the app has been asked to perform — what travels from any of the three
/// entry points (sweeper, Reclaim, auto-remove) to the single verified removal path.
struct WorktreeRemovalCandidate: Equatable, Sendable {
  var ref: WorktreeRef
  var prunable: Bool
  /// Only ever true for a row whose discard the human confirmed in the sweeper.
  var force: Bool
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
    /// The one gate every removal passes through, *at removal time*: candidates whose
    /// worktree is bound to a currently-running loop — in any open project — are
    /// dropped here, whatever a snapshot claimed when they were selected. `blocked`
    /// carries what the caller already refused to attempt, so one report covers both.
    case performRemovals(
      projectPath: String, candidates: [WorktreeRemovalCandidate], blocked: [String])
    /// Every removal reports back, even when it worked: a removal that git refused
    /// used to be swallowed whole, and a sweeper that closes on a click it did not
    /// carry out is indistinguishable from one that did.
    case removalsFinished(projectPath: String, failures: [String])
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
  @Dependency(\.remoteGitClient) var remoteGitClient
  @Dependency(\.worktreePolicyClient) var worktreePolicyClient

  var body: some Reducer<AppFeature.State, AppFeature.Action> {
    Reduce { state, action in
      switch action {
      case .worktrees(.sweepRequested(let path)):
        guard let project = state.projects[id: path], Self.tracksWorktrees(path)
        else { return .none }
        // Every open project's loops, not just this one's: two projects can share a
        // repository (a linked worktree opened as its own folder), and a sibling's
        // running loop must read as bound here too.
        state.worktreeSweep = WorktreeSweepFeature.State(
          projectPath: path,
          projectName: project.graph.project.name,
          nodes: allNodes(in: state))
        return .none

      case .worktrees(.sweepDismissed):
        let path = state.worktreeSweep?.projectPath
        state.worktreeSweep = nil
        guard let path else { return .none }
        return reloadStats(path, nodes: allNodes(in: state))

      // Remove keeps the sheet up and does the work back here, in the background — a
      // child effect would die with the sheet's state the moment it nils, and the sheet
      // is where the answer has to land. The child reducer ran first: if it raised the
      // discard confirmation, nothing happens yet.
      //
      // The sheet's assessments can be minutes old, so nothing is removed off them
      // directly: the effect re-inspects git (fresh dirtiness, fresh prunability;
      // vanished rows drop out) and routes through `.performRemovals`, where bindings
      // are re-read from the *live* graphs.
      case .worktrees(.sweep(.removeTapped)), .worktrees(.sweep(.removeConfirmed)):
        guard let sweep = state.worktreeSweep, !sweep.isConfirmingRemoval, !sweep.isRemoving
        else { return .none }
        let doomed = sweep.selected
        guard !doomed.isEmpty else { return .none }
        let path = sweep.projectPath
        state.worktreeSweep?.failure = nil
        state.worktreeSweep?.isRemoving = true
        return .run { [gitClient, remoteGitClient] send in
          let fresh: [WorktreeInspection]
          if let location = RemoteProjectLocation.parse(projectPath: path) {
            fresh = (try? await remoteGitClient.inspectWorktrees(location)) ?? []
          } else {
            fresh = (try? await gitClient.inspectWorktrees(path)) ?? []
          }
          let freshByPath = Dictionary(
            uniqueKeysWithValues: fresh.map { ($0.ref.worktreePath, $0) })
          var candidates: [WorktreeRemovalCandidate] = []
          var blocked: [String] = []
          for assessment in doomed {
            guard let current = freshByPath[assessment.ref.worktreePath] else { continue }
            // Forcing is decided on what git says *now*; consent is what the human gave
            // to the sheet. A worktree that has grown uncommitted files since the list
            // was built would fail an unforced removal without a word, so it is refused
            // out loud instead.
            let needsForce = !current.facts.prunable && !current.facts.clean
            guard !needsForce || assessment.removalDiscardsFiles else {
              blocked.append(
                "\(current.ref.displayName): uncommitted files appeared since this list "
                  + "was built — reopen Worktrees and confirm the discard")
              continue
            }
            candidates.append(
              WorktreeRemovalCandidate(
                ref: current.ref, prunable: current.facts.prunable, force: needsForce))
          }
          await send(
            .worktrees(
              .performRemovals(projectPath: path, candidates: candidates, blocked: blocked)))
        }

      case .worktrees(.performRemovals(let path, let candidates, let blocked)):
        // The removal-time binding check, against every open project's current graph.
        let occupied = Set(
          allNodes(in: state).filter { !$0.isResolved }
            .compactMap(\.worktreeBinding?.worktreePath))
        let claimed = candidates.filter { occupied.contains($0.ref.worktreePath) }
        let cleared = candidates.filter { !occupied.contains($0.ref.worktreePath) }
        let refused =
          blocked
          + claimed.map { "\($0.ref.displayName): a loop is running in it now" }
        guard !cleared.isEmpty else {
          return .send(.worktrees(.removalsFinished(projectPath: path, failures: refused)))
        }
        return .run { [gitClient, remoteGitClient] send in
          var failures = refused
          for candidate in cleared {
            do {
              if let location = RemoteProjectLocation.parse(projectPath: path) {
                try await remoteGitClient.removeWorktreeAndBranch(
                  location, candidate.ref, candidate.prunable, candidate.force)
              } else {
                try await gitClient.removeWorktreeAndBranch(
                  candidate.ref, candidate.prunable, candidate.force)
              }
            } catch {
              failures.append("\(candidate.ref.displayName): \(Self.reason(error))")
            }
          }
          await send(.worktrees(.removalsFinished(projectPath: path, failures: failures)))
        }

      case .worktrees(.removalsFinished(let path, let failures)):
        let reload = reloadStats(path, nodes: allNodes(in: state))
        guard state.worktreeSweep?.projectPath == path else { return reload }
        state.worktreeSweep?.isRemoving = false
        guard !failures.isEmpty else {
          state.worktreeSweep = nil
          return reload
        }
        // The sheet stays up with the reason on it, and re-reads git so the rows agree
        // with what is actually still there.
        state.worktreeSweep?.failure = failures.joined(separator: "\n")
        state.worktreeSweep?.selection = []
        return .merge(reload, .send(.worktrees(.sweep(.task))))

      // Selecting a folder re-reads its worktrees — the one moment a worktree created
      // outside the app (a terminal's `git worktree add`, a loop's own plumbing) gets
      // picked up without waiting for a graph broadcast.
      case .projectHeaderTapped(let path):
        // Remote repos are always git repos (validated on add); local ones need the check.
        let isRemote = RemoteProjectLocation.parse(projectPath: path) != nil
        guard Self.tracksWorktrees(path), isRemote || Self.isGitRepository(path)
        else { return .none }
        return reloadStats(path, nodes: allNodes(in: state))

      case .worktrees(.statsLoaded(let path, let stats)):
        state.worktreeStats[path] = stats
        // Mirrored into the project's own state, so the canvas — which only holds a
        // project-scoped store — can put the count on its `Worktrees…` menu item.
        state.projects[id: path]?.worktreeStats = stats
        return .none

      case .worktrees(.statsReloadRequested(let path)):
        return reloadStats(path, nodes: allNodes(in: state))

      case .worktrees(.settingsRequested(let path)):
        state.projectSettingsPath = path
        return .none

      case .worktrees(.settingsDismissed):
        let path = state.projectSettingsPath
        state.projectSettingsPath = nil
        // A changed threshold should be visible the moment the sheet closes — the chip
        // and titlebar notice re-derive from stats, so refresh them rather than leaving
        // the new line to take effect at the next broadcast.
        guard let path, Self.tracksWorktrees(path) else { return .none }
        return reloadStats(path, nodes: allNodes(in: state))

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
      // action; the removal routes through the same verified gate as everything else —
      // an offer can be minutes old, and another loop may have bound the worktree since.
      case .projects(.element(id: let path, action: .reclaimWorktreeTapped(let nodeID))):
        guard let node = state.projects[id: path]?.graph.nodes[id: nodeID],
          let ref = node.worktreeBinding
        else { return .none }
        return .send(
          .worktrees(
            .performRemovals(
              projectPath: path,
              candidates: [WorktreeRemovalCandidate(ref: ref, prunable: false, force: false)],
              blocked: [])))

      default:
        return .none
      }
    }
  }
}

/// The reducer's helpers, in an extension so the reducer body stays the only thing
/// in the type.
extension AppWorktreesReducer {
  /// Git's own words for why a removal failed, without the Swift error wrapper around
  /// them — "contains modified or untracked files" is the whole answer, and the rest of
  /// `GitClientError`'s description is noise on a sheet.
  static func reason(_ error: any Error) -> String {
    guard case .commandFailed(_, _, let output) = error as? GitClientError else {
      return String(describing: error)
    }
    let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    let message = lines.first { !$0.isEmpty && !$0.hasPrefix("hint:") } ?? ""
    guard !message.isEmpty else { return String(describing: error) }
    return message.hasPrefix("fatal: ") ? String(message.dropFirst("fatal: ".count)) : message
  }

  /// The global graph is not a folder — it has nothing to sweep.
  static func tracksWorktrees(_ path: String) -> Bool {
    path != LoopGraphScope.globalPath
  }

  /// `.git` is a directory in a primary checkout and a file in a linked worktree —
  /// either means git has something to say about this folder. Checked before any
  /// broadcast-driven git call so a plain folder never spawns `git` processes.
  private static func isGitRepository(_ path: String) -> Bool {
    FileManager.default.fileExists(
      atPath: (path as NSString).appendingPathComponent(".git"))
  }

  /// Every open project's loops. Bindings are always derived from this, never one
  /// project's — two projects can share a repository, and a sibling's running loop
  /// must count as binding a worktree here.
  private func allNodes(
    in state: AppFeature.State, replacing path: String? = nil, with graph: LoopGraph? = nil
  ) -> [LoopNode] {
    state.projects.flatMap { project -> [LoopNode] in
      if let path, let graph, project.id == path { return Array(graph.nodes) }
      return Array(project.graph.nodes)
    }
  }

  /// What one broadcast means for hygiene: a project appearing or its binding set
  /// changing refreshes the stats, and a loop crossing into resolution is the resolve
  /// moment — assessed, then removed or offered per the folder's policy.
  private func graphChangedEffects(
    _ state: AppFeature.State, next graph: LoopGraph
  ) -> Effect<AppFeature.Action> {
    let path = graph.project.path
    let isRemote = RemoteProjectLocation.parse(projectPath: path) != nil
    guard Self.tracksWorktrees(path), isRemote || Self.isGitRepository(path) else { return .none }
    let previous = state.projects[id: path]?.graph
    let changed = Array(graph.nodes)

    let newlyResolved = changed.filter { node in
      node.isResolved && node.worktreeBinding != nil
        && previous?.nodes[id: node.id].map { !$0.isResolved } == true
    }
    let bindingsChanged =
      Set((previous?.nodes ?? []).compactMap(\.worktreeBinding?.worktreePath))
      != Set(changed.compactMap(\.worktreeBinding?.worktreePath))

    // Bindings come from every project, with the broadcast's graph standing in for
    // the one it is about — state still holds that project's previous graph here.
    let nodes = allNodes(in: state, replacing: path, with: graph)
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
    .run { [gitClient, remoteGitClient] send in
      let inspections: [WorktreeInspection]
      let location = RemoteProjectLocation.parse(projectPath: path)
      if let location {
        guard let result = try? await remoteGitClient.inspectWorktrees(location) else { return }
        inspections = result
      } else {
        guard let result = try? await gitClient.inspectWorktrees(path) else { return }
        inspections = result
      }
      let assessments = WorktreeSweepFeature.assessments(inspections, nodes: nodes)
      func stats(totalBytes: Int64) -> WorktreeFolderStats {
        WorktreeFolderStats(
          total: assessments.count,
          reclaimable: assessments.filter { $0.tier == .safeToRemove }.count,
          totalBytes: totalBytes)
      }
      // Counts first — they're what the menus and chip text need — then the disk walk
      // for the byte total that decides the amber threshold. Serial `du` here: this is
      // a background refresh, and four-wide is reserved for the sweeper a human is
      // actively looking at.
      await send(.worktrees(.statsLoaded(projectPath: path, stats(totalBytes: 0))))
      var totalBytes: Int64 = 0
      for assessment in assessments where !assessment.facts.prunable {
        if let location {
          totalBytes +=
            await remoteGitClient.worktreeSizeBytes(location, assessment.ref.worktreePath) ?? 0
        } else {
          totalBytes += await gitClient.worktreeSizeBytes(assessment.ref.worktreePath) ?? 0
        }
      }
      await send(.worktrees(.statsLoaded(projectPath: path, stats(totalBytes: totalBytes))))
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
    return .run { [gitClient, remoteGitClient] send in
      let inspections: [WorktreeInspection]
      let location = RemoteProjectLocation.parse(projectPath: path)
      if let location {
        guard let result = try? await remoteGitClient.inspectWorktrees(location) else { return }
        inspections = result
      } else {
        guard let result = try? await gitClient.inspectWorktrees(path) else { return }
        inspections = result
      }
      guard let inspection = inspections.first(where: { $0.ref.worktreePath == ref.worktreePath })
      else { return }
      // One worktree's size is worth the wait here: "312 MB left behind" is half of
      // what makes the card's offer worth answering.
      var facts = inspection.facts
      if let location {
        facts.sizeBytes = await remoteGitClient.worktreeSizeBytes(location, ref.worktreePath)
      } else {
        facts.sizeBytes = await gitClient.worktreeSizeBytes(ref.worktreePath)
      }
      let assessment = WorktreeAssessment(
        ref: inspection.ref,
        facts: facts,
        binding: WorktreeAssessment.binding(
          forWorktreePath: ref.worktreePath, in: others),
        loopTitle: title)
      guard assessment.tier == .safeToRemove else { return }
      switch policy.onResolveLanded {
      case .remove:
        // Never forced (the safe tier is clean by definition), and routed through the
        // verified gate: the inspection above took real time, and a loop can have
        // claimed the worktree meanwhile.
        await send(
          .worktrees(
            .performRemovals(
              projectPath: path,
              candidates: [
                WorktreeRemovalCandidate(
                  ref: inspection.ref, prunable: inspection.facts.prunable, force: false)
              ],
              blocked: [])))
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
