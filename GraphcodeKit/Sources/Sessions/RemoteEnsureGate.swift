import Foundation

/// One remote ensure per node at a time.
///
/// `remoteEnsureInvocation` is create-only in a single remote shell, which closes the
/// window between *its own* `zmx get` and `zmx run`. What it cannot close is the window
/// between two ensures: an ssh dial that hangs rather than refuses is bounded by
/// `ConnectTimeout`, `ServerAlive` and `runRemoteRetrying`'s backoff at well over a
/// minute, so it is still in flight when the next `ProjectRegistry` liveness sweep comes
/// round. Two dials whose checks both miss both run — and a `zmx run` that lands second
/// types the entire launch command into the agent the first one started, which is the
/// composer-bar leak the single-shell `||` exists to prevent.
///
/// Keyed by node rather than by host: two loops on one machine have no reason to wait
/// for each other, and their sessions are distinct.
actor RemoteEnsureGate {
  static let shared = RemoteEnsureGate()

  private var inFlight: Set<UUID> = []

  /// `false` when an ensure for this node is already running, which the caller should
  /// treat as "already handled" — the dial in flight is doing the same work.
  func begin(_ nodeID: UUID) -> Bool {
    inFlight.insert(nodeID).inserted
  }

  func end(_ nodeID: UUID) {
    inFlight.remove(nodeID)
  }
}
