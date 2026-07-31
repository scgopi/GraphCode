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
  private let ensureSession: (@Sendable (LoopNode, String?) -> Void)?
  private let terminateSession: (@Sendable (LoopNode, String?) -> Void)?
  private let evaluatePredicate: (@Sendable (ShellPredicate) async -> Bool)?
  private let deliverMessage: (@Sendable (LoopNode, String, String?) async -> Bool)?
  private let captureScript: (@Sendable (ShellPredicate) async -> String?)?
  private let readUsage: (@Sendable (LoopNode) async -> UsageSample?)?

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
    evaluatePredicate: (@Sendable (ShellPredicate) async -> Bool)? = ShellPredicateEvaluator
      .evaluate,
    deliverMessage: (@Sendable (LoopNode, String, String?) async -> Bool)? =
      CLISessionBackend.deliverMessage,
    captureScript: (@Sendable (ShellPredicate) async -> String?)? = ShellPredicateEvaluator.capture,
    readUsage: (@Sendable (LoopNode) async -> UsageSample?)? = CLISessionBackend.readUsage
  ) {
    persistence = ProjectPersistence(baseDirectory: persistenceDirectory)
    self.ensureSession = ensureSession
    self.terminateSession = terminateSession
    self.evaluatePredicate = evaluatePredicate
    self.deliverMessage = deliverMessage
    self.captureScript = captureScript
    self.readUsage = readUsage
  }

  // MARK: - Connections

  public func addConnection(id: UUID, fileDescriptor: Int32) {
    connectionFileDescriptors[id] = fileDescriptor
  }

  public func removeConnection(_ id: UUID) async {
    for path in connectionProjectPaths[id] ?? [] {
      guard let store = stores[path] else { continue }
      await store.removeConnection(id)
    }
    connectionFileDescriptors.removeValue(forKey: id)
    connectionProjectPaths.removeValue(forKey: id)
  }

  // MARK: - Commands

  public func handle(_ command: DaemonCommand, connectionID: UUID) async {
    guard let fileDescriptor = connectionFileDescriptors[connectionID] else { return }

    switch command {
    case .listRecentProjects:
      send(.recentProjectsListed(persistence.loadRecentProjects()), to: fileDescriptor)

    case .openProject(let path):
      await open(Self.canonicalize(path), for: connectionID, fileDescriptor: fileDescriptor)

    case .restoreOpenProjects:
      // Each of these broadcasts a `.graphChanged` exactly as `.openProject` would, so
      // the app reuses its ordinary "graph for a project I don't know yet = project
      // opened" path instead of needing a restore-shaped event of its own.
      for path in persistence.loadOpenProjects() {
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

    case .deleteProjectGraph(let path):
      let canonicalPath = Self.canonicalize(path)
      await close(canonicalPath, for: connectionID)
      persistence.forgetProject(path: canonicalPath)
      // Drop the in-memory store too, or a later reopen would resurrect the graph we
      // just deleted from the one still sitting in `stores`.
      stores.removeValue(forKey: canonicalPath)
      persistence.deleteGraph(path: canonicalPath)

    case .graphCommand(let path, let inner):
      guard let store = stores[Self.canonicalize(path)] else { return }
      await store.handle(inner)
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
    rememberOpen(canonicalPath)
  }

  private func close(_ canonicalPath: String, for connectionID: UUID) async {
    if let store = stores[canonicalPath] {
      await store.removeConnection(connectionID)
    }
    connectionProjectPaths[connectionID]?.remove(canonicalPath)
    persistence.saveOpenProjects(persistence.loadOpenProjects().filter { $0 != canonicalPath })
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
      onGraphChanged: { updatedGraph in persistence.saveGraph(updatedGraph) },
      onEnsureSession: ensureSession,
      onTerminateSession: terminateSession,
      onEvaluatePredicate: evaluatePredicate,
      onDeliverMessage: deliverMessage,
      onCaptureScript: captureScript,
      onReadUsage: readUsage,
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
    return newStore
  }

  /// The global graph's reserved path is a `graphcode://` URL, and a remote project's
  /// is an `ssh://` one — neither is a folder, and running either through
  /// `fileURLWithPath` would mangle it into a relative path under the cwd and route its
  /// commands to a store that doesn't exist.
  private static func canonicalize(_ path: String) -> String {
    guard path != LoopGraphScope.globalPath,
      RemoteProjectLocation.parse(projectPath: path) == nil
    else { return path }
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
