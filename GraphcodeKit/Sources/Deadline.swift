import Foundation

/// Runs `operation` with a deadline, answering `nil` when it has not finished in time.
///
/// The slower of the two is **abandoned**, not cancelled and waited for, and that is the
/// whole point. A structured `withTaskGroup` race cannot bound anything here: the group
/// waits for every child before it returns, so a child that never finishes takes the
/// timeout down with it. The reads this exists for are exactly that kind — a presence
/// probe reaches `PTYProcessSession.waitCollectingOutput`, which ends only when the
/// child's `terminationHandler` closes the stream, and `ssh`'s `ConnectTimeout` bounds
/// the *connect*, never a command already running on a host that has gone away
/// (`RemoteEnsureGate` documents the same wedge from the other side).
///
/// Cancelling the loser is therefore hygiene rather than the mechanism: a task blocked
/// on a pipe that will never close ignores it. What makes this safe is that nothing
/// awaits the abandoned task, so it costs one suspended task until its subprocess is
/// reaped, and the caller is already gone.
func withDeadline<T: Sendable>(
  _ deadline: Duration, _ operation: @escaping @Sendable () async -> T
) async -> T? {
  let relay = DeadlineRelay<T>()
  let work = Task.detached { await relay.settle(await operation()) }
  let timer = Task.detached {
    try? await Task.sleep(for: deadline)
    await relay.settle(nil)
  }
  let answer = await relay.wait()
  work.cancel()
  timer.cancel()
  return answer
}

/// Whichever of the two tasks arrives first wins; the other's answer is dropped rather
/// than resuming a continuation twice.
private actor DeadlineRelay<T: Sendable> {
  private var answer: T??
  private var waiter: CheckedContinuation<T?, Never>?

  func settle(_ value: T?) {
    guard answer == nil else { return }
    answer = .some(value)
    guard let waiter else { return }
    self.waiter = nil
    waiter.resume(returning: value)
  }

  func wait() async -> T? {
    if let answer { return answer }
    return await withCheckedContinuation { self.waiter = $0 }
  }
}
