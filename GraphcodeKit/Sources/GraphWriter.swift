import Foundation

/// Persists graphs off the actor that changes them — the disk-side twin of
/// `OutboundChannel` (issue #307).
///
/// `GraphStore.broadcast()` used to call `persistence.saveGraph` synchronously, so every
/// mutation held the `GraphStore` actor across a full serialise-and-write — the shape
/// #291 removed from the socket path, one layer over: a memo measured at 0.03–2.13 s
/// against a 0.003 s socket round trip, with the variance coming from the filesystem.
///
/// A save is handed here and the actor returns. One serial queue writes; consecutive
/// saves of the same project collapse to the newest snapshot (the graph is a value and
/// the file is a whole, so nothing older has anything left to say), which turns a burst
/// of memos into one write. `flush` waits for everything queued — what the daemon calls
/// on its way out, and what a test calls before reading the file back.
public final class GraphWriter: @unchecked Sendable {
  private let persistence: ProjectPersistence
  private let queue = DispatchQueue(label: "dev.graphcode.graphcoded.persist", qos: .utility)
  private let lock = NSLock()
  private var pending: [String: LoopGraph] = [:]
  private var scheduled = false

  public init(persistence: ProjectPersistence) {
    self.persistence = persistence
  }

  /// Queues the newest snapshot of a project and returns at once.
  public func save(_ graph: LoopGraph) {
    lock.lock()
    pending[graph.project.path] = graph
    let drainNeeded = !scheduled
    scheduled = true
    lock.unlock()
    guard drainNeeded else { return }
    queue.async { [self] in drain() }
  }

  /// Returns once everything queued so far is on disk.
  public func flush() {
    queue.sync { drain() }
  }

  private func drain() {
    while true {
      lock.lock()
      guard let (_, graph) = pending.first else {
        scheduled = false
        lock.unlock()
        return
      }
      pending.removeValue(forKey: graph.project.path)
      lock.unlock()
      persistence.saveGraph(graph)
    }
  }
}
