import Foundation

/// One remote ensure per node at a time — as a **lease**, not a flag.
///
/// `remoteEnsureInvocation` is create-only in a single remote shell, which closes the
/// window between *its own* `zmx get` and `zmx run`. What it cannot close is the window
/// between two ensures: two dials whose checks both miss both run, and a `zmx run` that
/// lands second types the entire launch command into the agent the first one started.
///
/// **Why a lease and not a `Set`.** The dial this gates can hang without ever returning:
/// `runRemoteRetrying` → `PTYProcessSession.waitCollectingOutput` ends only when the
/// child's `terminationHandler` finishes the stream, and there is no timeout in that
/// chain. `ssh` is invoked with `ControlMaster=auto`, and a *wedged* master — a laptop
/// slept mid-session, a Codespace stopped while holding the socket — blocks a new client
/// on the unix socket, where neither `ConnectTimeout` nor `ServerAliveInterval` applies.
/// With a plain `Set` that node's entry would never be released and every later ensure
/// would return immediately: the loop silently dead until the daemon restarts. That is a
/// worse failure than the double-launch being prevented, so the entry expires.
///
/// `leaseDuration` is far longer than any healthy dial (three attempts at
/// `ConnectTimeout=10` plus 1s and 2s backoff) and short enough that a wedge costs
/// minutes, not the process lifetime. Re-dialling after it is safe in practice: a dial
/// wedged before it reached the host ran nothing at all, and one wedged after `zmx run`
/// leaves a session the next dial's `zmx get` finds.
///
/// Keyed by node rather than by host: two loops on one machine have no reason to wait for
/// each other, and their sessions are distinct.
actor RemoteEnsureGate {
  static let shared = RemoteEnsureGate()

  static let leaseDuration: TimeInterval = 300

  private var leases: [UUID: Date] = [:]

  /// The moment a lease was taken, which is also proof of *which* lease it is. Returning
  /// it rather than a bare `true` is what stops a dial from releasing a lease that is no
  /// longer its own — see `end`.
  ///
  /// `nil` when a live lease is held for this node, which the caller should treat as
  /// "already handled": the dial holding it is doing the same work.
  func begin(_ nodeID: UUID, now: Date = Date()) -> Date? {
    if let held = leases[nodeID], now.timeIntervalSince(held) < Self.leaseDuration {
      return nil
    }
    leases[nodeID] = now
    return now
  }

  /// Releases the lease only if it is still the one `token` was issued for.
  ///
  /// Unconditional removal loses exactly the race the lease exists to survive: dial A
  /// wedges and its lease expires, dial B takes a fresh one, then A's ssh finally
  /// returns and clears *B's* lease — leaving B in flight with the gate open, so the
  /// next sweep tick starts a third dial alongside it. Both would miss on `zmx get`
  /// (the host has just come back, its sessions are gone) and both would `zmx run`.
  func end(_ nodeID: UUID, token: Date) {
    guard leases[nodeID] == token else { return }
    leases.removeValue(forKey: nodeID)
  }
}
