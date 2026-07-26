import Foundation

/// Owns every open project's `GraphStore`, keyed by canonicalized folder path — this is
/// what `graphcoded` instantiates instead of a single bare `GraphStore` from Phase 4 on
/// (see docs/07-roadmap.md#phase-4--projects). Multi-project routing lives entirely
/// here: `GraphStore` itself still only ever handles one graph and has no idea this
/// layer exists.
///
/// One connection (one socket, one `graphcode.app` instance) can have at most one
/// project "open" at a time, but can switch which project that is over the connection's
/// lifetime without reconnecting — `connectionProjectPaths` tracks that so `.openProject`
/// can detach a connection from its previous project's `GraphStore` before joining the
/// new one.
public actor ProjectRegistry {
  private let persistence: ProjectPersistence
  private var stores: [String: GraphStore] = [:]
  private var connectionFileDescriptors: [UUID: Int32] = [:]
  private var connectionProjectPaths: [UUID: String] = [:]

  public init(persistenceDirectory: URL) {
    persistence = ProjectPersistence(baseDirectory: persistenceDirectory)
  }

  // MARK: - Connections

  public func addConnection(id: UUID, fileDescriptor: Int32) {
    connectionFileDescriptors[id] = fileDescriptor
  }

  public func removeConnection(_ id: UUID) async {
    if let path = connectionProjectPaths[id], let store = stores[path] {
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
      let canonicalPath = Self.canonicalize(path)
      if let previousPath = connectionProjectPaths[connectionID], previousPath != canonicalPath,
        let previousStore = stores[previousPath]
      {
        await previousStore.removeConnection(connectionID)
      }
      let store = store(forProjectPath: canonicalPath)
      connectionProjectPaths[connectionID] = canonicalPath
      await store.addConnection(id: connectionID, fileDescriptor: fileDescriptor)
      let project = await store.graph.project
      persistence.recordOpened(
        ProjectRef(path: project.path, name: project.name, lastOpenedAt: Date()))

    case .graphCommand(let path, let inner):
      guard let store = stores[Self.canonicalize(path)] else { return }
      await store.handle(inner)
    }
  }

  // MARK: - Store lookup

  private func store(forProjectPath path: String) -> GraphStore {
    if let existing = stores[path] { return existing }
    let graph =
      persistence.loadGraph(path: path)
      ?? LoopGraph(project: ProjectRef(path: path, name: Self.displayName(for: path)))
    let persistence = self.persistence
    let newStore = GraphStore(graph: graph) { updatedGraph in
      persistence.saveGraph(updatedGraph)
    }
    stores[path] = newStore
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
