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
  private let ensureSession: (@Sendable (LoopNode) -> Void)?

  /// `ensureSession` defaults to `ZmxSessionLauncher`'s — every `GraphStore` this
  /// registry creates gets it, so a time-based node's session is (re)started as soon as
  /// its project's graph is loaded. Tests pass their own closure, or `nil` to launch
  /// nothing at all.
  public init(
    persistenceDirectory: URL,
    ensureSession: (@Sendable (LoopNode) -> Void)? = ZmxSessionLauncher.ensureSession
  ) {
    persistence = ProjectPersistence(baseDirectory: persistenceDirectory)
    self.ensureSession = ensureSession
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

  // MARK: - Store lookup

  private func store(forProjectPath path: String) async -> GraphStore {
    if let existing = stores[path] { return existing }
    let graph =
      persistence.loadGraph(path: path)
      ?? LoopGraph(project: ProjectRef(path: path, name: Self.displayName(for: path)))
    let persistence = self.persistence
    let newStore = GraphStore(
      graph: graph,
      onGraphChanged: { updatedGraph in persistence.saveGraph(updatedGraph) },
      onEnsureSession: ensureSession)
    stores[path] = newStore
    // Only on first load of this project — a time-based node's session outlives the app
    // but not a reboot, so something has to restart it, and this is the moment the
    // persisted graph is first seen. Already-running sessions are left untouched.
    await newStore.ensureTimeBasedSessions()
    return newStore
  }

  private static func canonicalize(_ path: String) -> String {
    URL(fileURLWithPath: path).resolvingSymlinksInPath().path
  }

  private static func displayName(for path: String) -> String {
    URL(fileURLWithPath: path).lastPathComponent
  }

  // MARK: - Unicast reply

  private func send(_ event: DaemonEvent, to fileDescriptor: Int32) {
    guard let data = try? JSONEncoder().encode(event) else { return }
    try? FramedMessageIO.writeFrame(data, to: fileDescriptor)
  }
}
