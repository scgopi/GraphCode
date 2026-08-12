import Foundation

public struct ProjectRegistryCommandResult: Equatable, Sendable {
  public let response: DaemonEvent?
  public let error: String?

  public init(response: DaemonEvent? = nil, error: String? = nil) {
    self.response = response
    self.error = error
  }
}

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
/// The registry also owns which projects the sidebar should show on next launch, kept in
/// `open-projects.json` separately from the recents index. That separation is what gives
/// the sidebar's context menu three distinct verbs: `.closeProject` drops a project from
/// the open set only, `.forgetProject` also removes it from recents, and
/// `.deleteProjectGraph` additionally discards its saved loops.
public actor ProjectRegistry {
  private let persistence: ProjectPersistence
  private let platformPaths: any PlatformPaths
  private let replayStore: DaemonReplayStore
  private var stores: [String: GraphStore] = [:]
  private var connections: [UUID: DaemonConnectionChannel] = [:]
  private var connectionProjectPaths: [UUID: Set<String>] = [:]
  private let ensureSession: (@Sendable (LoopNode, String?) -> Void)?
  private let terminateSession: (@Sendable (LoopNode, String?) -> Void)?
  private let evaluatePredicate: (@Sendable (ShellPredicate) async -> Bool)?
  private let deliverMessage: (@Sendable (LoopNode, String, String?) async -> Bool)?
  private let captureScript: (@Sendable (ShellPredicate) async -> String?)?
  private let readUsage: (@Sendable (LoopNode, String?) async -> UsageSample?)?
  private let readActivity: (@Sendable (LoopNode, String?) async -> String?)?
  private let readPresence: (@Sendable (LoopNode, String?) async -> PresenceReading)?
  /// Non-nil only while at least one client is attached — see `startPresencePolling`.
  private var presencePoller: Task<Void, Never>?

  /// These default to the real `ZmxSessionLauncher`/`ShellPredicateEvaluator` closures —
  /// every `GraphStore` this registry creates gets them, so an unattended node's session
  /// is (re)started as soon as its project's graph is loaded, torn down when the node is
  /// deleted, and a goal's stop condition is polled while it runs. Tests pass their own
  /// closures, or `nil` to touch no real sessions or subprocesses at all.
  public init(
    persistenceDirectory: URL,
    platformPaths: any PlatformPaths = CurrentPlatformPaths.value,
    replayStore: DaemonReplayStore = DaemonReplayStore(),
    ensureSession: (@Sendable (LoopNode, String?) -> Void)? = CLISessionBackend.ensureSession,
    terminateSession: (@Sendable (LoopNode, String?) -> Void)? =
      CLISessionBackend.terminateSession,
    evaluatePredicate: (@Sendable (ShellPredicate) async -> Bool)? = ShellPredicateEvaluator
      .evaluate,
    deliverMessage: (@Sendable (LoopNode, String, String?) async -> Bool)? =
      CLISessionBackend.deliverMessage,
    captureScript: (@Sendable (ShellPredicate) async -> String?)? = ShellPredicateEvaluator.capture,
    readUsage: (@Sendable (LoopNode, String?) async -> UsageSample?)? =
      CLISessionBackend.readUsage,
    readActivity: (@Sendable (LoopNode, String?) async -> String?)? =
      CLISessionBackend.readActivity,
    readPresence: (@Sendable (LoopNode, String?) async -> PresenceReading)? =
      CLISessionBackend.readPresence
  ) {
    self.platformPaths = platformPaths
    persistence = ProjectPersistence(
      baseDirectory: persistenceDirectory, platformPaths: platformPaths)
    self.replayStore = replayStore
    self.ensureSession = ensureSession
    self.terminateSession = terminateSession
    self.evaluatePredicate = evaluatePredicate
    self.deliverMessage = deliverMessage
    self.captureScript = captureScript
    self.readUsage = readUsage
    self.readActivity = readActivity
    self.readPresence = readPresence
  }

  // MARK: - Connections

  public func addConnection(
    id: UUID,
    connection: any DaemonConnection,
    mode: DaemonProtocolMode = .v1,
    clientID: UUID? = nil,
    subscription: DaemonWireSubscription? = nil,
    replayStore: DaemonReplayStore? = nil
  ) async {
    let channel = DaemonConnectionChannel(
      connection: connection, mode: mode, clientID: clientID,
      subscription: subscription, replayStore: replayStore ?? self.replayStore)
    await addConnection(id: id, channel: channel)
  }

  public func addConnection(id: UUID, channel: DaemonConnectionChannel) async {
    connections[id] = channel
    startPresencePolling()
  }

  #if canImport(Darwin)
    /// Compatibility seam for existing macOS callers; the registry stores only the
    /// channel abstraction after this boundary.
    public func addConnection(id: UUID, fileDescriptor: Int32) async {
      await addConnection(
        id: id,
        connection: UnixSocketConnection(fileDescriptor: fileDescriptor))
    }
  #endif

  public func removeConnection(_ id: UUID) async {
    for path in connectionProjectPaths[id] ?? [] {
      guard let store = stores[path] else { continue }
      await store.removeConnection(id)
    }
    let channel = connections.removeValue(forKey: id)
    connectionProjectPaths.removeValue(forKey: id)
    if connections.isEmpty { stopPresencePolling() }
    try? await channel?.close()
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

  private var remoteSweeper: Task<Void, Never>?

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
  deinit { remoteSweeper?.cancel() }

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
    _ = await apply(command, connectionID: connectionID)
  }

  /// Applies a command and snapshots its correlated result before returning to the
  /// daemon read loop. Keeping mutation and response selection together prevents a
  /// concurrent disconnect or command from turning a rejected mutation into a stale
  /// successful graph response.
  public func apply(
    _ command: DaemonCommand,
    connectionID: UUID
  ) async -> ProjectRegistryCommandResult? {
    guard let channel = connections[connectionID] else { return nil }
    let broadcastErrors: Bool
    if case .v2 = channel.mode {
      broadcastErrors = false
    } else {
      broadcastErrors = true
    }
    var response: DaemonEvent? = nil
    var error: String? = nil

    switch command {
    case .listRecentProjects:
      let recentProjects = persistence.loadRecentProjects()
      await send(.recentProjectsListed(recentProjects), to: connectionID)
      response = .recentProjectsListed(recentProjects)
      error = nil

    case .openProject(let path):
      guard Self.isOpenable(path, platformPaths: platformPaths) else {
        return ProjectRegistryCommandResult(error: "project path is not openable")
      }
      let snapshot = await open(
        Self.canonicalize(path, platformPaths: platformPaths),
        for: connectionID,
        channel: channel)
      response = .graphChanged(snapshot)
      error = nil

    case .restoreOpenProjects:
      // Each of these broadcasts a `.graphChanged` exactly as `.openProject` would, so
      // the app reuses its ordinary "graph for a project I don't know yet = project
      // opened" path instead of needing a restore-shaped event of its own.
      //
      // Only the spelling is re-checked here, not whether the directory is there: these
      // paths were openable when they were added, and a project on an unmounted volume
      // has to come back when the volume does. Nothing is deleted from the stored set
      // either way — `close` is the only thing that removes from it.
      for path in persistence.loadOpenProjects()
      where Self.isWellFormedProjectPath(path, platformPaths: platformPaths) {
        await open(
          Self.canonicalize(path, platformPaths: platformPaths),
          for: connectionID,
          channel: channel)
      }
      response = .recentProjectsListed(persistence.loadRecentProjects())
      error = nil

    case .openGlobalGraph:
      let snapshot = await open(LoopGraphScope.globalPath, for: connectionID, channel: channel)
      response = .graphChanged(snapshot)
      error = nil

    case .closeProject(let path):
      let snapshot = await close(
        Self.canonicalize(path, platformPaths: platformPaths),
        for: connectionID)
      response = snapshot.map(DaemonEvent.graphChanged)
      error = nil

    case .forgetProject(let path):
      let canonicalPath = Self.canonicalize(path, platformPaths: platformPaths)
      _ = await close(canonicalPath, for: connectionID)
      persistence.forgetProject(path: canonicalPath)
      error = nil

    case .deleteProjectGraph(let path):
      let canonicalPath = Self.canonicalize(path, platformPaths: platformPaths)
      _ = await close(canonicalPath, for: connectionID)
      persistence.forgetProject(path: canonicalPath)
      // Drop the in-memory store too, or a later reopen would resurrect the graph we
      // just deleted from the one still sitting in `stores`.
      stores.removeValue(forKey: canonicalPath)
      persistence.deleteGraph(path: canonicalPath)
      response = .recentProjectsListed(persistence.loadRecentProjects())
      error = nil

    case .graphCommand(let path, let inner):
      guard let store = stores[Self.canonicalize(path, platformPaths: platformPaths)] else {
        return ProjectRegistryCommandResult(error: "project is not open")
      }
      let result = await store.handle(inner, broadcastErrors: broadcastErrors)
      switch result {
      case .applied(let graph):
        response = .graphChanged(graph)
        error = nil
      case .rejected(let message, _):
        error = message
      }
    }

    return ProjectRegistryCommandResult(response: error == nil ? response : nil, error: error)
  }

  /// Produces a correlated v2 response after the command has been applied. The v1
  /// protocol continues to use its existing broadcast-only acknowledgement path.
  public func responseEvent(for command: DaemonCommand) async -> DaemonEvent? {
    switch command {
    case .listRecentProjects:
      return .recentProjectsListed(persistence.loadRecentProjects())
    case .restoreOpenProjects:
      return .recentProjectsListed(persistence.loadRecentProjects())
    case .openProject(let path), .closeProject(let path), .forgetProject(let path):
      let canonical = Self.canonicalize(path, platformPaths: platformPaths)
      guard let store = stores[canonical] else { return nil }
      return .graphChanged(await store.graph)
    case .deleteProjectGraph:
      return .recentProjectsListed(persistence.loadRecentProjects())
    case .openGlobalGraph:
      guard let store = stores[LoopGraphScope.globalPath] else { return nil }
      return .graphChanged(await store.graph)
    case .graphCommand(let path, _):
      guard let store = stores[Self.canonicalize(path, platformPaths: platformPaths)] else {
        return nil
      }
      return .graphChanged(await store.graph)
    }
  }

  private func open(
    _ canonicalPath: String, for connectionID: UUID, channel: DaemonConnectionChannel
  ) async -> LoopGraph {
    let store = await store(forProjectPath: canonicalPath)
    connectionProjectPaths[connectionID, default: []].insert(canonicalPath)
    let snapshot = await store.addConnection(id: connectionID, channel: channel)
    // The global graph is always resident and isn't a folder anyone opened, so it stays
    // out of both the recents list and the restore-on-launch set — the app asks for it
    // by name every launch instead.
    guard canonicalPath != LoopGraphScope.globalPath else { return snapshot }
    let project = snapshot.project
    persistence.recordOpened(
      ProjectRef(path: project.path, name: project.name, lastOpenedAt: Date()))
    rememberOpen(canonicalPath)
    return snapshot
  }

  private func close(_ canonicalPath: String, for connectionID: UUID) async -> LoopGraph? {
    var snapshot: LoopGraph?
    if let store = stores[canonicalPath] {
      snapshot = await store.removeConnection(connectionID, leaveReplay: true)
    }
    connectionProjectPaths[connectionID]?.remove(canonicalPath)
    persistence.saveOpenProjects(persistence.loadOpenProjects().filter { $0 != canonicalPath })
    return snapshot
  }

  /// Append rather than insert-at-front: the sidebar should come back in the order it
  /// was built up, not most-recent-first — that's what the recents list is for.
  private func rememberOpen(_ canonicalPath: String) {
    var open = persistence.loadOpenProjects()
    guard !open.contains(canonicalPath) else { return }
    open.append(canonicalPath)
    persistence.saveOpenProjects(open)
  }

  // MARK: - The global Orchestrator Graph

  /// Loads the one always-resident global graph
  /// (docs/02-graph-of-loops.md#the-orchestrator-graph--global-vs-project-scope).
  ///
  /// It's just another store keyed by a reserved path, which is what keeps persistence,
  /// broadcasting, and command routing identical to a project's. What makes it global is
  /// where its `.spawn` edges are allowed to point, not a separate code path.
  public func openGlobalGraph(for connectionID: UUID) async {
    guard let channel = connections[connectionID] else { return }
    await open(LoopGraphScope.globalPath, for: connectionID, channel: channel)
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
    let canonicalPath = Self.canonicalize(targetPath, platformPaths: platformPaths)
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
    let replayStore = self.replayStore
    // A cross-graph spawn arrives here as a plain request; hopping through an unstructured
    // `Task` is what lets this actor re-enter itself to reach a *different* store without
    // deadlocking on its own isolation.
    let spawnIntoProject: @Sendable (String, NodeDraft) -> Void = { [weak self] target, draft in
      Task { await self?.spawnIntoProject(target, draft: draft) }
    }
    let onConnectionFailure: @Sendable (UUID) -> Void = { [weak self] connectionID in
      Task { await self?.removeConnection(connectionID) }
    }
    let newStore = GraphStore(
      graph: graph,
      onGraphChanged: { updatedGraph in persistence.saveGraph(updatedGraph) },
      onGraphEvent: { event in
        guard case .graphChanged(let updatedGraph) = event else { return [:] }
        return replayStore.append(
          event: event, projectPath: updatedGraph.project.path)
      },
      onConnectionFailure: onConnectionFailure,
      onEnsureSession: ensureSession,
      onTerminateSession: terminateSession,
      onEvaluatePredicate: evaluatePredicate,
      onDeliverMessage: deliverMessage,
      onCaptureScript: captureScript,
      onReadUsage: readUsage,
      onReadActivity: readActivity,
      onReadPresence: readPresence,
      onSpawnIntoProject: spawnIntoProject,
      // The node memory log (`NodeMemory`): episode records in, whole directory out
      // when the node is deleted. Keyed by this store's project path, captured here so
      // `GraphStore` stays unaware of where memory lives — the same split as sessions.
      onAppendMemory: { nodeID, entry in
        NodeMemory.append(entry, projectPath: path, nodeID: nodeID)
      },
      onRemoveMemory: { nodeID in
        NodeMemory.remove(projectPath: path, nodeID: nodeID)
      })
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
  static func isWellFormedProjectPath(
    _ path: String,
    platformPaths: any PlatformPaths = CurrentPlatformPaths.value
  ) -> Bool {
    if path == LoopGraphScope.globalPath { return true }
    if RemoteProjectLocation.parse(projectPath: path) != nil { return true }
    return (try? platformPaths.canonicalProjectPath(path)) != nil
  }

  /// Whether a path can be opened as a project right now: well-formed, and a directory
  /// that is actually there.
  ///
  /// The existence half is deliberately not applied when restoring. It is applied here
  /// because this is the door every client knocks on, and without it a mistyped or
  /// already-deleted path became a project with a store, a recents entry and a place in
  /// the restore set — `~/.graphcode/projects` accumulates one JSON per such ghost.
  static func isOpenable(
    _ path: String,
    platformPaths: any PlatformPaths = CurrentPlatformPaths.value
  ) -> Bool {
    guard isWellFormedProjectPath(path, platformPaths: platformPaths) else { return false }
    if path == LoopGraphScope.globalPath { return true }
    if RemoteProjectLocation.parse(projectPath: path) != nil { return true }
    guard let canonicalPath = try? platformPaths.canonicalProjectPath(path) else {
      return false
    }
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(
      atPath: canonicalPath, isDirectory: &isDirectory)
    return exists && isDirectory.boolValue
  }

  private static func canonicalize(
    _ path: String,
    platformPaths: any PlatformPaths = CurrentPlatformPaths.value
  ) -> String {
    guard path != LoopGraphScope.globalPath,
      RemoteProjectLocation.parse(projectPath: path) == nil
    else { return path }
    return (try? platformPaths.canonicalProjectPath(path)) ?? path
  }

  private static func displayName(for path: String) -> String {
    if let remote = RemoteProjectLocation.parse(projectPath: path) {
      return remote.displayName
    }
    return URL(fileURLWithPath: path).lastPathComponent
  }

  // MARK: - Unicast reply

  private func send(_ event: DaemonEvent, to connectionID: UUID) async {
    guard let channel = connections[connectionID] else { return }
    do {
      try await channel.sendEvent(event)
    } catch {
      await removeConnection(connectionID)
    }
  }
}
