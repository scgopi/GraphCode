import Foundation

/// Owns every open project's `GraphStore`, keyed by canonicalized folder path — this is
/// what `graphcoded` instantiates instead of a single bare `GraphStore` from Phase 4 on
/// (see docs/07-roadmap.md#phase-4--projects). Multi-project routing lives entirely
/// here: `GraphStore` itself still only ever handles one graph and has no idea this
/// layer exists.
///
/// One connection (one socket, one `graphcode.app` instance) can have any number of
/// projects open at once — the sidebar shows every folder the app has opened, not just
/// the most recent one (see docs/07-roadmap.md's Projects phase follow-up). `.openProject`
/// *adds* to the connection's joined-project set rather than replacing it;
/// `connectionProjectPaths` tracks that set so a full disconnect can detach from every
/// joined `GraphStore`, not just one.
///
/// The open set is shared, not per-connection: whoever opens a folder — the app, the CLI,
/// an editor plugin driving the CLI — adds it for everyone, so every attached sidebar is
/// joined to it there and then (`joinSidebars`) instead of finding out at its next launch.
///
/// The registry also owns which projects the sidebar should show on next launch, kept in
/// `open-projects.json` separately from the recents index. That separation is what gives
/// the sidebar's context menu three distinct verbs: `.closeProject` drops a project from
/// the open set only, `.forgetProject` also removes it from recents, and
/// `.deleteProjectGraph` additionally discards its saved loops.
public actor ProjectRegistry {
  private let persistence: ProjectPersistence
  private var stores: [String: GraphStore] = [:]
  private var connectionFileDescriptors: [UUID: Int32] = [:]
  private var connectionProjectPaths: [UUID: Set<String>] = [:]
  /// Connections that asked for the whole open set (`.restoreOpenProjects`) rather than
  /// one named project — see `sidebarSubscribers`.
  private var sidebarConnections: Set<UUID> = []
  private let ensureSession: (@Sendable (LoopNode, String?) -> Void)?
  private let terminateSession: (@Sendable (LoopNode, String?) -> Void)?
  private let restartSession: (@Sendable (LoopNode, String?) async -> Bool)?
  private let evaluatePredicate: (@Sendable (ShellPredicate) async -> Bool)?
  private let checkPredicate: (@Sendable (ShellPredicate) async -> PredicateOutcome?)?
  private let deliverMessage: (@Sendable (LoopNode, String, String?) async -> Bool)?
  private let captureScript: (@Sendable (ShellPredicate) async -> String?)?
  private let readUsage: (@Sendable (LoopNode, String?) async -> UsageSample?)?
  private let readActivity: (@Sendable (LoopNode, String?) async -> String?)?
  private let readSummary: (@Sendable (LoopNode, String?) async -> SummaryReading?)?
  private let readPresence: (@Sendable (LoopNode, String?) async -> PresenceReading)?
  private let sessionAlive: (@Sendable (LoopNode, String?) async -> Bool)?
  private let composeBoard:
    (@Sendable (LoopNode, LoopSummary, String?, String?) async -> SummaryBoard?)?
  /// Non-nil only while at least one client is attached — see `startPresencePolling`.
  private var presencePoller: Task<Void, Never>?
  /// Runs only while the sleep assertion is held — see `refreshAwakeAssertion`.
  private var awakeRecheck: Task<Void, Never>?

  /// These default to the real `ZmxSessionLauncher`/`ShellPredicateEvaluator` closures —
  /// every `GraphStore` this registry creates gets them, so an unattended node's session
  /// is (re)started as soon as its project's graph is loaded, torn down when the node is
  /// deleted, and a goal's stop condition is polled while it runs. Tests pass their own
  /// closures, or `nil` to touch no real sessions or subprocesses at all.
  public init(
    persistenceDirectory: URL,
    ensureSession: (@Sendable (LoopNode, String?) -> Void)? = CLISessionBackend.ensureSession,
    terminateSession: (@Sendable (LoopNode, String?) -> Void)? =
      CLISessionBackend.terminateSession,
    restartSession: (@Sendable (LoopNode, String?) async -> Bool)? =
      CLISessionBackend.restartSession,
    evaluatePredicate: (@Sendable (ShellPredicate) async -> Bool)? = ShellPredicateEvaluator
      .evaluate,
    checkPredicate: (@Sendable (ShellPredicate) async -> PredicateOutcome?)? =
      ShellPredicateEvaluator.check,
    deliverMessage: (@Sendable (LoopNode, String, String?) async -> Bool)? =
      CLISessionBackend.deliverMessage,
    captureScript: (@Sendable (ShellPredicate) async -> String?)? = ShellPredicateEvaluator.capture,
    readUsage: (@Sendable (LoopNode, String?) async -> UsageSample?)? =
      CLISessionBackend.readUsage,
    readActivity: (@Sendable (LoopNode, String?) async -> String?)? =
      CLISessionBackend.readActivity,
    readSummary: (@Sendable (LoopNode, String?) async -> SummaryReading?)? =
      CLISessionBackend.readSummary,
    readPresence: (@Sendable (LoopNode, String?) async -> PresenceReading)? =
      CLISessionBackend.readPresence,
    sessionAlive: (@Sendable (LoopNode, String?) async -> Bool)? = CLISessionBackend.sessionAlive,
    composeBoard: (@Sendable (LoopNode, LoopSummary, String?, String?) async -> SummaryBoard?)? =
      CLISessionBackend.composeBoard,
    reapCondemnedSessions: Bool = false
  ) {
    persistence = ProjectPersistence(baseDirectory: persistenceDirectory)
    self.ensureSession = ensureSession
    self.terminateSession = terminateSession
    self.restartSession = restartSession
    self.evaluatePredicate = evaluatePredicate
    self.checkPredicate = checkPredicate
    self.deliverMessage = deliverMessage
    self.captureScript = captureScript
    self.readUsage = readUsage
    self.readActivity = readActivity
    self.readSummary = readSummary
    self.readPresence = readPresence
    self.sessionAlive = sessionAlive
    self.composeBoard = composeBoard
    // The reap half of the two-phase kill (`CondemnedSessions`): once at startup, for a
    // delete whose daemon died between condemning a session and confirming it dead, and
    // then on a timer for kills `zmx` failed transiently. This is explicit rather than
    // inferred from injected session closures: tests commonly provide non-nil stubs and
    // must never touch the user's real zmx.
    if reapCondemnedSessions {
      condemnedReaper = Task {
        await ZmxSessionLauncher.reapCondemnedSessions()
        while !Task.isCancelled {
          try? await Task.sleep(for: Self.condemnedReapInterval)
          guard !Task.isCancelled else { return }
          await ZmxSessionLauncher.reapCondemnedSessions()
        }
      }
    }
  }

  // MARK: - Connections

  public func addConnection(id: UUID, fileDescriptor: Int32) {
    connectionFileDescriptors[id] = fileDescriptor
    startPresencePolling()
  }

  public func removeConnection(_ id: UUID) async {
    for path in connectionProjectPaths[id] ?? [] {
      guard let store = stores[path] else { continue }
      await store.removeConnection(id)
    }
    connectionFileDescriptors.removeValue(forKey: id)
    connectionProjectPaths.removeValue(forKey: id)
    sidebarConnections.remove(id)
    if connectionFileDescriptors.isEmpty { stopPresencePolling() }
  }

  // MARK: - Presence polling

  /// How often a live session is asked what it is doing.
  ///
  /// The trade is plain: this is the lag between a loop finishing its turn and its card
  /// admitting it, and the cost is one `zmx get` per *unresolved loop* per tick. Not per
  /// app and not per project — per loop, because `zmx` has no way to read many sessions'
  /// labels at once (`list --where k=v` is in its help but returns every session whatever
  /// you filter on, so it cannot be used to batch this).
  ///
  /// Fifteen seconds puts a handful of millisecond-long socket round-trips a minute
  /// against a canvas that tells the truth within a glance. It is the one number to turn
  /// up if a graph ever grows to hundreds of loops.
  static let presencePollInterval: Duration = .seconds(15)

  /// Polling runs only while a client is attached — see `GraphStore.pollPresence` for why
  /// the same guard is repeated per store. Started by the first connection and cancelled
  /// by the last, so a daemon running loops with no app open spends nothing on this.
  private func startPresencePolling() {
    guard presencePoller == nil, readPresence != nil else { return }
    presencePoller = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: Self.presencePollInterval)
        guard !Task.isCancelled else { return }
        await self?.pollPresence()
      }
    }
  }

  private func stopPresencePolling() {
    presencePoller?.cancel()
    presencePoller = nil
  }

  // MARK: - Remote liveness

  /// How often a remote project's unattended sessions are checked for existence.
  ///
  /// Local loops need no such sweep: their sessions die with the machine, and the machine
  /// coming back restarts `graphcoded`, which loads the graph and calls
  /// `ensureUnattendedSessions`. A *remote* host reboots — a Codespace stops on idle and
  /// starts again — without this daemon restarting at all, so that one call site never
  /// fires and every loop on that host stays dead until the app is relaunched.
  ///
  /// Unlike the presence poll this runs with no client attached, because a loop being
  /// alive matters when nobody is watching and a reading does not. On a healthy tick the
  /// dial is a bare `zmx get` — `remoteEnsureInvocation` keeps the hooks write and the
  /// file delivery behind that check precisely so this can be cheap — multiplexed onto
  /// the host's existing `ControlMaster` connection.
  static let remoteLivenessSweepInterval: Duration = .seconds(60)

  /// Generous next to the remote sweep's minute: on a healthy machine the condemned
  /// list is empty and a tick is one file read, but a tick that finds work spawns
  /// processes, and a session that survived three confirmed kill attempts is not going
  /// to die to a faster clock.
  static let condemnedReapInterval: Duration = .seconds(300)

  private var remoteSweeper: Task<Void, Never>?
  private var condemnedReaper: Task<Void, Never>?

  /// Started by the first remote project this daemon loads and left running: a store is
  /// never removed for being idle, and the sweep costs nothing on a tick where no project
  /// is remote.
  private func startRemoteLivenessSweep() {
    guard remoteSweeper == nil, ensureSession != nil else { return }
    remoteSweeper = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: Self.remoteLivenessSweepInterval)
        guard !Task.isCancelled else { return }
        await self?.sweepRemoteSessions()
      }
    }
  }

  /// The registry outlives the daemon in practice, but a `Task` holding only a weak
  /// `self` would otherwise keep waking every minute after the registry it sweeps for is
  /// gone — the same reason `GraphStore` cancels its goal pollers here.
  deinit {
    remoteSweeper?.cancel()
    condemnedReaper?.cancel()
    awakeRecheck?.cancel()
  }

  /// `ensureSession` is fire-and-forget by contract (`CLISessionBackend.ensureSession`
  /// spawns a detached task), so this returns well before the dials it started finish and
  /// the loop below is an ordering, not a throttle. What bounds the work is
  /// `RemoteEnsureGate`: one ensure per node at a time, so a slow tick cannot pile a
  /// second dial onto the same session.
  private func sweepRemoteSessions() async {
    for (path, store) in stores where RemoteProjectLocation.parse(projectPath: path) != nil {
      await store.ensureUnattendedSessionsAlive()
    }
  }

  /// Takes or drops the sleep assertion to match what is running right now
  /// (`AwakeAssertion`), across every open project.
  ///
  /// Called on every graph change rather than on a timer, because a graph change is
  /// exactly when the answer can differ. The one thing a graph change cannot notice is
  /// the *setting* being switched off while loops keep running, which is why holding the
  /// assertion also starts a slow re-check — and only while it is held, so a daemon with
  /// this switched off, or with nothing running, still keeps no timer at all.
  private func refreshAwakeAssertion() async {
    var running = 0
    for store in stores.values { running += await store.runningLoopCount() }
    let enabled = GraphcodeSettingsStore.load().keepsMacAwakeWhileLoopsRun
    let shouldHold = AwakeAssertion.shouldStayAwake(runningLoops: running, enabled: enabled)
    await AwakeAssertion.shared.apply(shouldHold: shouldHold, runningLoops: running)
    if shouldHold { startAwakeRecheck() } else { stopAwakeRecheck() }
  }

  static let awakeRecheckInterval: Duration = .seconds(60)

  private func startAwakeRecheck() {
    guard awakeRecheck == nil else { return }
    awakeRecheck = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: Self.awakeRecheckInterval)
        guard !Task.isCancelled else { return }
        await self?.refreshAwakeAssertion()
      }
    }
  }

  private func stopAwakeRecheck() {
    awakeRecheck?.cancel()
    awakeRecheck = nil
  }

  /// Sequential rather than concurrent across projects: each store's poll already spawns
  /// one subprocess per loop, and firing every project's at once would turn a quiet
  /// background tick into a burst of them.
  private func pollPresence() async {
    for store in stores.values {
      await store.pollPresence()
    }
  }

  // MARK: - Commands

  public func handle(_ command: DaemonCommand, connectionID: UUID) async {
    guard let fileDescriptor = connectionFileDescriptors[connectionID] else { return }

    switch command {
    case .listRecentProjects:
      send(.recentProjectsListed(persistence.loadRecentProjects()), to: fileDescriptor)

    case .openProject(let path):
      switch routing(for: path, isSidebar: sidebarConnections.contains(connectionID)) {
      case .project(let canonicalPath):
        await open(canonicalPath, for: connectionID, fileDescriptor: fileDescriptor)
      case .refused(let reason):
        send(.errorOccurred(reason), to: fileDescriptor)
      }

    case .restoreOpenProjects:
      // Each of these broadcasts a `.graphChanged` exactly as `.openProject` would, so
      // the app reuses its ordinary "graph for a project I don't know yet = project
      // opened" path instead of needing a restore-shaped event of its own.
      //
      // Only the spelling is re-checked here, not whether the directory is there: these
      // paths were openable when they were added, and a project on an unmounted volume
      // has to come back when the volume does. Nothing is deleted from the stored set
      // either way — `close` is the only thing that removes from it.
      // Asking for the whole open set is what marks a client as a sidebar: from here on
      // it is joined to projects *other* clients open, so `graphcode status <new folder>`
      // puts a row in a running app instead of one that only appears next launch.
      sidebarConnections.insert(connectionID)
      for path in prunedOpenProjects() where Self.isWellFormedProjectPath(path) {
        await open(path, for: connectionID, fileDescriptor: fileDescriptor)
      }

    case .openGlobalGraph:
      await open(LoopGraphScope.globalPath, for: connectionID, fileDescriptor: fileDescriptor)

    case .closeProject(let path):
      await close(Self.canonicalize(path), for: connectionID)

    case .forgetProject(let path):
      let canonicalPath = Self.canonicalize(path)
      await close(canonicalPath, for: connectionID)
      persistence.forgetProject(path: canonicalPath)
      if path != canonicalPath { persistence.forgetProject(path: path) }

    case .deleteProjectGraph(let path):
      let canonicalPath = Self.canonicalize(path)
      await close(canonicalPath, for: connectionID)
      persistence.forgetProject(path: canonicalPath)
      // The graph is the only handle on every loop's detached session, so its deletion
      // has to end them first — dropping it with the sessions alive left every agent in
      // the project running forever with nothing pointing at it. Read from the resident
      // store when there is one, else straight from disk: going through
      // `store(forProjectPath:)` would run its load-time `ensureUnattendedSessions`,
      // *starting* sessions on the way to killing them. Memory goes with each loop, the
      // same as single-node deletion.
      let graph = await stores[canonicalPath]?.graph ?? persistence.loadGraph(path: canonicalPath)
      for node in graph?.nodesAtAnyDepth ?? [] {
        terminateSession?(node, canonicalPath)
        NodeMemory.remove(projectPath: canonicalPath, nodeID: node.id)
      }
      // Drop the in-memory store too, or a later reopen would resurrect the graph we
      // just deleted from the one still sitting in `stores`.
      stores.removeValue(forKey: canonicalPath)
      persistence.deleteGraph(path: canonicalPath)

    case .graphCommand(let path, let inner):
      // Routed the same way the open was, so a client that had its path redirected to the
      // project containing it addresses that project here too. Without the second half,
      // the open would land on one graph and every command after it on nothing at all —
      // silently, which is how a `node create` could look like it hung.
      switch routing(for: path, isSidebar: sidebarConnections.contains(connectionID)) {
      case .project(let canonicalPath):
        guard let store = stores[canonicalPath] else {
          send(.errorOccurred("\(path) isn't open — open it first."), to: fileDescriptor)
          return
        }
        await store.handle(inner)
      case .refused(let reason):
        send(.errorOccurred(reason), to: fileDescriptor)
      }
    }
  }

  private func open(_ canonicalPath: String, for connectionID: UUID, fileDescriptor: Int32) async {
    let store = await store(forProjectPath: canonicalPath)
    connectionProjectPaths[connectionID, default: []].insert(canonicalPath)
    await store.addConnection(id: connectionID, fileDescriptor: fileDescriptor)
    // The global graph is always resident and isn't a folder anyone opened, so it stays
    // out of both the recents list and the restore-on-launch set — the app asks for it
    // by name every launch instead.
    guard canonicalPath != LoopGraphScope.globalPath else { return }
    let project = await store.graph.project
    persistence.recordOpened(
      ProjectRef(path: project.path, name: project.name, lastOpenedAt: Date()))
    guard rememberOpen(canonicalPath) else { return }
    await joinSidebars(to: store, at: canonicalPath, excluding: connectionID)
  }

  /// Joins every attached sidebar client to a project one of *them* — or the CLI, or a
  /// plugin driving it — just added to the open set, so it arrives as an ordinary
  /// `.graphChanged` snapshot.
  ///
  /// The open set is one shared list, not a per-connection view: `graphcode status
  /// <folder>` persists the folder for everyone, and every sidebar restores the same set
  /// at launch. Without this that shared list only reached a *running* app on relaunch,
  /// which is precisely how a folder added from outside the app looked like it hadn't
  /// been added at all.
  ///
  /// Only sidebars, and only on the open that was new. A one-shot CLI connection reads
  /// frames until the `.graphChanged` for the project it named (`runAndPrintGraph`, and
  /// the same loop in the remote python shim), so joining it to an unrelated project
  /// would hand it another project's graph to print.
  private func joinSidebars(to store: GraphStore, at path: String, excluding opener: UUID) async {
    for id in sidebarConnections where id != opener {
      guard let fileDescriptor = connectionFileDescriptors[id] else { continue }
      connectionProjectPaths[id, default: []].insert(path)
      await store.addConnection(id: id, fileDescriptor: fileDescriptor)
    }
  }

  private func close(_ canonicalPath: String, for connectionID: UUID) async {
    if let store = stores[canonicalPath] {
      await store.removeConnection(connectionID)
    }
    connectionProjectPaths[connectionID]?.remove(canonicalPath)
    // Compared canonically, not literally: a project added before remote paths were
    // normalized is stored under the spelling it arrived with, and closing it sends that
    // spelling back through `canonicalize`. Filtering on the raw string left those rows
    // in the open set and un-closable.
    persistence.saveOpenProjects(
      persistence.loadOpenProjects().filter { Self.canonicalize($0) != canonicalPath })
  }

  /// Clears out the empty twins a pre-normalization daemon left in the sidebar: a stored
  /// path that is only another stored path spelled differently — a trailing slash, a
  /// doubled separator — and whose graph never received a loop or a board post.
  ///
  /// Deliberately timid. A twin with anything in it is left exactly where it is: it is
  /// somebody's work, and folding it into the project it duplicates would make those
  /// loops vanish rather than be found. Its graph file is kept either way; only the
  /// sidebar entry and the recents row go, and re-opening the path brings both back.
  private func prunedOpenProjects() -> [String] {
    let stored = persistence.loadOpenProjects()
    let kept = stored.filter { path in
      let canonical = Self.canonicalize(path)
      // Only ever a *later* twin, so the first spelling of a project always survives even
      // when every stored spelling of it is a variant.
      guard path != canonical,
        stored.prefix(while: { $0 != path }).contains(where: { Self.canonicalize($0) == canonical })
      else { return true }
      let graph = persistence.loadGraph(path: path)
      let isEmpty = (graph?.nodesAtAnyDepth.isEmpty ?? true) && (graph?.artifactory.isEmpty ?? true)
      if isEmpty { persistence.forgetProject(path: path) }
      return !isEmpty
    }
    if kept != stored { persistence.saveOpenProjects(kept) }
    return kept
  }

  /// Append rather than insert-at-front: the sidebar should come back in the order it
  /// was built up, not most-recent-first — that's what the recents list is for.
  ///
  /// Returns whether this was the open that added the project, which is what tells
  /// `open` there is news to push to the other sidebars: a re-open of something already
  /// in the set (every restored project, every `graphcode status` on a folder the app is
  /// already showing) is not.
  @discardableResult
  private func rememberOpen(_ canonicalPath: String) -> Bool {
    var open = persistence.loadOpenProjects()
    guard !open.contains(canonicalPath) else { return false }
    open.append(canonicalPath)
    persistence.saveOpenProjects(open)
    return true
  }

  // MARK: - Which project a named path belongs to

  enum PathRouting: Equatable {
    case project(String)
    case refused(String)
  }

  /// Where a path a client named should be routed, and whether it may become a *new*
  /// project rather than an existing one.
  ///
  /// Opening is create-if-missing, because that is how a folder becomes a project at all:
  /// `graphcode status <folder>` from a shell is a supported way to add one. What that
  /// missed is that most paths a *loop* names are not new projects — they are its own
  /// worktree, its working directory, or its project's path spelled slightly differently.
  /// Each of those quietly became a second project: its own graph, its own recents entry,
  /// its own row in the sidebar under the same name, with the loops the agent then created
  /// inside it where nobody was looking. A codespace made it trivial to hit, since a
  /// remote path is never checked against a filesystem: every spelling of one was openable.
  ///
  /// So two kinds of path are never a new project when a shell client names them:
  ///
  /// - **A folder inside a project that already exists** is that project — a worktree
  ///   under the repository, a subdirectory, the remote path of a codespace already added.
  /// - **A remote path this daemon has never seen.** Remote projects are added in the app,
  ///   which validates the connection over ssh first; nothing typed at a shell can be
  ///   checked that way, so an unknown one is a typo or a spelling variant of a known one.
  ///
  /// The app is exempt from both, and is told apart by having asked for the whole open set
  /// (`sidebarConnections`): opening a nested folder or adding a remote host is a
  /// deliberate human act there, and refusing it would break Add Folder.
  func routing(for path: String, isSidebar: Bool) -> PathRouting {
    guard Self.isWellFormedProjectPath(path) else {
      return .refused(
        "\(path) isn't a project path — name an absolute folder, an ssh:// or codespace:// "
          + "project, or \(LoopGraphScope.globalPath).")
    }
    let canonicalPath = Self.canonicalize(path)
    guard canonicalPath != LoopGraphScope.globalPath else { return .project(canonicalPath) }
    let known = knownProjectPaths()
    if known.contains(canonicalPath) { return .project(canonicalPath) }
    if !isSidebar, let container = Self.project(containing: canonicalPath, in: known) {
      return .project(container)
    }
    if RemoteProjectLocation.parse(projectPath: canonicalPath) != nil {
      guard isSidebar else {
        return .refused(
          "graphcode doesn't know a project at \(canonicalPath). Run `graphcode projects` "
            + "for the exact path; a remote repository or codespace is added in the app.")
      }
      return .project(canonicalPath)
    }
    guard Self.isOpenable(canonicalPath) else {
      return .refused(
        "there's no folder at \(canonicalPath). Run `graphcode projects` for the paths "
          + "graphcode knows.")
    }
    return .project(canonicalPath)
  }

  /// Every project this daemon knows about, canonically spelled: what the sidebar has
  /// open, what recents remembers, and whatever is resident.
  private func knownProjectPaths() -> Set<String> {
    var paths = Set(persistence.loadOpenProjects().map(Self.canonicalize))
    paths.formUnion(persistence.loadRecentProjects().map { Self.canonicalize($0.path) })
    paths.formUnion(stores.keys)
    return paths
  }

  /// The deepest known project a path lies inside — deepest so that a nested project a
  /// human deliberately opened wins over the repository around it.
  static func project(containing path: String, in known: Set<String>) -> String? {
    known
      .filter { $0 != LoopGraphScope.globalPath && path.hasPrefix($0 + "/") }
      .max { $0.count < $1.count }
  }

  // MARK: - The global Orchestrator Graph

  /// Loads the one always-resident global graph
  /// (docs/02-graph-of-loops.md#the-orchestrator-graph--global-vs-project-scope).
  ///
  /// It's just another store keyed by a reserved path, which is what keeps persistence,
  /// broadcasting, and command routing identical to a project's. What makes it global is
  /// where its `.spawn` edges are allowed to point, not a separate code path.
  public func openGlobalGraph(for connectionID: UUID) async {
    guard let fileDescriptor = connectionFileDescriptors[connectionID] else { return }
    await open(LoopGraphScope.globalPath, for: connectionID, fileDescriptor: fileDescriptor)
  }

  /// Delivers a cross-graph spawn into its target project.
  ///
  /// The target has to already be open. That's a real constraint rather than an
  /// oversight: instantiating into a project nobody has opened would start sessions
  /// against a folder the human isn't looking at, and silently. A dropped spawn is
  /// visible next time they open it; a secret one never is.
  ///
  /// Non-recursive by construction — the global graph spawns into project graphs, and
  /// nothing spawns back. Enforced here rather than trusted: a project graph naming the
  /// global path as its spawn target is refused.
  private func spawnIntoProject(_ targetPath: String, draft: NodeDraft) async {
    let canonicalPath = Self.canonicalize(targetPath)
    guard canonicalPath != LoopGraphScope.globalPath else { return }
    guard let store = stores[canonicalPath] else { return }
    await store.handle(.createNode(draft))
  }

  // MARK: - Store lookup

  private func store(forProjectPath path: String) async -> GraphStore {
    if let existing = stores[path] { return existing }
    let scope = LoopGraphScope(projectPath: path, name: Self.displayName(for: path))
    let graph = persistence.loadGraph(path: path) ?? LoopGraph(scope: scope)
    let persistence = self.persistence
    // A cross-graph spawn arrives here as a plain request; hopping through an unstructured
    // `Task` is what lets this actor re-enter itself to reach a *different* store without
    // deadlocking on its own isolation.
    let spawnIntoProject: @Sendable (String, NodeDraft) -> Void = { [weak self] target, draft in
      Task { await self?.spawnIntoProject(target, draft: draft) }
    }
    let newStore = GraphStore(
      graph: graph,
      onGraphChanged: { [weak self] updatedGraph in
        persistence.saveGraph(updatedGraph)
        // Every state change is a chance for the last running loop to have stopped, or
        // the first to have started — see `refreshAwakeAssertion`.
        Task { await self?.refreshAwakeAssertion() }
      },
      onEnsureSession: ensureSession,
      onTerminateSession: terminateSession,
      onRestartSession: restartSession,
      onEvaluatePredicate: evaluatePredicate,
      onCheckPredicate: checkPredicate,
      onDeliverMessage: deliverMessage,
      onCaptureScript: captureScript,
      onReadUsage: readUsage,
      onReadActivity: readActivity,
      onReadSummary: readSummary,
      onReadPresence: readPresence,
      onSessionAlive: sessionAlive,
      onSpawnIntoProject: spawnIntoProject,
      // The node memory log (`NodeMemory`): episode records in, whole directory out
      // when the node is deleted. Keyed by this store's project path, captured here so
      // `GraphStore` stays unaware of where memory lives — the same split as sessions.
      onAppendMemory: { nodeID, entry in
        NodeMemory.append(entry, projectPath: path, nodeID: nodeID)
      },
      onRemoveMemory: { nodeID in
        NodeMemory.remove(projectPath: path, nodeID: nodeID)
      },
      onRefinePlaybook: { nodeID, text in
        NodeMemory.refinePlaybook(text, projectPath: path, nodeID: nodeID)
      },
      onRollbackPlaybook: { nodeID in
        NodeMemory.rollbackPlaybook(projectPath: path, nodeID: nodeID)
      },
      onHeartbeatEnabled: { GraphcodeSettingsStore.load().daemonHeartbeatEnabled },
      onDefaultBackend: { GraphcodeSettingsStore.load().defaultBackend },
      onComposeBoard: composeBoard,
      onBoardsEnabled: {
        let settings = GraphcodeSettingsStore.load()
        // Both, and in this order: a board is drawn from the summary, so the picture is
        // meaningless without the reading that feeds it. Switching the rail off takes the
        // boards with it rather than leaving pictures of a run nothing is narrating.
        return settings.summarisesLoops && settings.visualisesSummaries
      },
      // What a following loop re-reads at its next run: home + this project's
      // `.graphcode/templates`, project winning on a filename collision. See
      // `TemplateStorage`.
      onResolveTemplate: { templateID, projectPath in
        TemplateStorage.shared.template(withID: templateID, projectPath: projectPath)
      },
      // Read fresh per command, the way the heartbeat toggle is: the app resolving
      // the beta ramp (or a hand edit) applies to the next post with no restart.
      onArtifactoryEnabled: { GraphcodeSettingsStore.load().artifactoryEnabled })
    stores[path] = newStore
    // Only on first load of this project — a time-based node's session outlives the app
    // but not a reboot, so something has to restart it, and this is the moment the
    // persisted graph is first seen. Already-running sessions are left untouched.
    await newStore.ensureUnattendedSessions()
    // The load-time ensure above is the *local* machine's reboot recovery. A remote host
    // reboots on its own schedule, so its loops need a repeating check as well.
    if RemoteProjectLocation.parse(projectPath: path) != nil { startRemoteLivenessSweep() }
    return newStore
  }

  /// The global graph's reserved path is a `graphcode://` URL, and a remote project's
  /// is an `ssh://` one — neither is a folder, and running either through
  /// `fileURLWithPath` would mangle it into a relative path under the cwd and route its
  /// commands to a store that doesn't exist.
  /// Whether a path is even the *shape* of a project — checked before `canonicalize`,
  /// which is where the damage was done.
  ///
  /// `URL(fileURLWithPath:)` resolves a relative path against the process's working
  /// directory, and an empty one resolves to that directory outright. `graphcoded` runs
  /// under launchd, whose working directory is `/`, so an empty path arriving from any
  /// client — `graphcode status "$UNSET"` is all it takes — became the root directory,
  /// which exists, so it opened, persisted, and came back every launch as a folder
  /// called "/".
  ///
  /// The root is refused even when spelled out. A project is scanned by the worktree
  /// sweeper and by git; pointed at `/` that is the whole disk.
  static func isWellFormedProjectPath(_ path: String) -> Bool {
    if path == LoopGraphScope.globalPath { return true }
    if RemoteProjectLocation.parse(projectPath: path) != nil { return true }
    // Absolute, and not the root however it is spelled: `/`, `//`, `/..` and `/a/..` all
    // reduce to the same directory.
    guard path.hasPrefix("/") else { return false }
    return RemoteProjectLocation.normalizedPath(path) != "/"
  }

  /// Whether a path can be opened as a project right now: well-formed, and a directory
  /// that is actually there.
  ///
  /// The existence half is deliberately not applied when restoring. It is applied here
  /// because this is the door every client knocks on, and without it a mistyped or
  /// already-deleted path became a project with a store, a recents entry and a place in
  /// the restore set — `~/.graphcode/projects` accumulates one JSON per such ghost.
  static func isOpenable(_ path: String) -> Bool {
    guard isWellFormedProjectPath(path) else { return false }
    if path == LoopGraphScope.globalPath { return true }
    if RemoteProjectLocation.parse(projectPath: path) != nil { return true }
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
    return exists && isDirectory.boolValue
  }

  /// The one spelling of a project's path — every store, every persisted entry and every
  /// `.graphChanged` is keyed on it. Public because the app has to key on it too: a
  /// project it asked for by the path a folder picker handed it comes back named by this,
  /// and `/tmp` vs `/private/tmp` is enough to make the two look like different projects.
  public static func canonicalize(_ path: String) -> String {
    guard path != LoopGraphScope.globalPath else { return path }
    // A remote path gets the textual half of the same treatment. It cannot be resolved
    // against this filesystem — the directory is on another machine — but the spellings
    // that fork one project into two are all textual: a trailing slash, a doubled
    // separator, a `.` segment. Left unnormalized, `codespace://cs/workspaces/repo/` and
    // `codespace://cs/workspaces/repo` were two projects, two graphs, and two rows in the
    // sidebar with the same name.
    if let remote = RemoteProjectLocation.parse(projectPath: path) {
      var normalized = remote
      normalized.remotePath = RemoteProjectLocation.normalizedPath(remote.remotePath)
      return normalized.projectPath
    }
    return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
  }

  private static func displayName(for path: String) -> String {
    if let remote = RemoteProjectLocation.parse(projectPath: path) {
      return remote.displayName
    }
    return URL(fileURLWithPath: path).lastPathComponent
  }

  // MARK: - Unicast reply

  private func send(_ event: DaemonEvent, to fileDescriptor: Int32) {
    guard let data = try? JSONEncoder().encode(event) else { return }
    try? FramedMessageIO.writeFrame(data, to: fileDescriptor)
  }
}
