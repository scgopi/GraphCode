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

  /// The newest snapshot of a project — the one still queued, if there is one, else
  /// the file. Every reader of the persisted graph goes through here rather than
  /// through the file: a save that has left the actor and not yet reached the disk is
  /// otherwise invisible, and a delete of a *closed* project (no live store) that read
  /// the file to find the loops whose sessions it must end would end fewer than exist
  /// and leave the rest running.
  public func load(path: String) -> LoopGraph? {
    lock.lock()
    let queued = pending[path]
    lock.unlock()
    if let queued { return queued }
    return persistence.loadGraph(path: path)
  }

  /// Drops any save still queued for a project, for a caller that is about to delete it.
  ///
  /// The queue exists to let a write land after the actor has moved on, which is exactly
  /// wrong once the graph is being thrown away: a drain that ran after `deleteGraph`
  /// would put the file back, and `load` would keep answering from the queue for a
  /// project that no longer exists. The delete is the one operation that has to reach
  /// into the queue rather than trail it.
  ///
  /// Synced against the drain, not just the pending table: a drain that has already
  /// popped a save still has the write ahead of it — a write made outside the lock, and
  /// one that would land after `deleteGraph` removed the file. Only the drain's
  /// completion makes "nothing queued" true, and the serial queue is where that
  /// ordering lives.
  public func forget(path: String) {
    queue.sync {
      lock.lock()
      pending.removeValue(forKey: path)
      lock.unlock()
    }
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
