import Foundation

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

/// The daemon's outbound half of one client connection: frames are handed over and
/// written by a thread of the channel's own, so a peer that has stopped reading can
/// never stall the caller that produced the frame.
///
/// This exists because of what `graphChanged` is. The daemon broadcasts the *whole*
/// graph to every connected client on every change, and that frame is a couple of orders
/// of magnitude larger than a unix socket's send buffer — 176 KB against `SO_SNDBUF`'s
/// 8 KB on the graph this was measured against. A blocking `write` of a frame that size
/// cannot be handed to the kernel and forgotten: it only completes as the peer drains,
/// repeatedly, mid-frame. The callers doing that writing were `GraphStore` and
/// `ProjectRegistry`, both actors, so one client that stopped reading for a moment —
/// which is exactly what the `graphcode` CLI does while it renders its output — parked a
/// `GraphStore` thread inside `write(2)`, and every other command for that project queued
/// behind it until that client happened to exit. Measured: a healthy round trip of 6 ms
/// became a hard timeout past 12 s, with one non-draining client attached and nothing
/// else wrong. That is issue #288 — `mail inbox` timing out against a daemon that was
/// never busy, only blocked.
///
/// A thread per channel rather than a shared queue: the write it performs blocks for as
/// long as the peer is wedged, and putting that on `DispatchQueue.global()` would tie up
/// a pool worker per stalled client — the same exhaustion one level down. Connections are
/// few and a thread that spends its life blocked on one descriptor costs nothing but its
/// stack.
final class OutboundChannel: @unchecked Sendable {
  /// How much undelivered data a channel keeps before it gives the client up for lost.
  ///
  /// With coalescing (below) a backlog is normally one snapshot, so this is a safety
  /// valve rather than a working limit: reaching it means a peer stopped reading and
  /// stayed stopped across many changes. Disconnecting it is the honest outcome — it is
  /// already arbitrarily far behind, and the graph it would eventually receive is one the
  /// daemon has long since replaced.
  static let maxBacklogBytes = 4 * 1024 * 1024

  private struct Frame {
    let data: Data
    /// Frames sharing a key supersede one another while undelivered — see `send`.
    let supersedingKey: String?
  }

  private let fileDescriptor: Int32
  private let condition = NSCondition()
  private var pending: [Frame] = []
  private var pendingBytes = 0
  private var isClosing = false
  private var isFinished = false

  init(fileDescriptor: Int32) {
    self.fileDescriptor = fileDescriptor
    // Captured strongly on purpose: the channel must outlive the registry's reference to
    // it, because the descriptor is closed by `pump` on its way out. A weak capture would
    // let a channel released without `close()` take its thread — and its unclosed
    // descriptor — with it.
    let thread = Thread { [self] in pump() }
    thread.name = "graphcoded.outbound.\(fileDescriptor)"
    thread.start()
  }

  /// Queues a frame and returns immediately.
  ///
  /// `supersedingKey` replaces any still-undelivered frame carrying the same key rather
  /// than queueing behind it. `graphChanged` uses this and is the reason it exists: the
  /// event carries the entire graph and never a diff, so a snapshot that has not left the
  /// building is worthless the moment a newer one exists, and a slow client should be
  /// caught up rather than walked through every state the graph passed through while it
  /// was not reading. Anything a client must see each time — an `errorOccurred` answering
  /// one command — passes `nil` and keeps its place in the queue.
  ///
  /// Returns `false` once the channel is finished, which is how a caller learns the
  /// connection is gone without having waited for a write to fail.
  @discardableResult
  func send(_ data: Data, supersedingKey: String? = nil) -> Bool {
    condition.lock()
    defer { condition.unlock() }
    guard !isClosing, !isFinished else { return false }

    if let supersedingKey {
      pending.removeAll { existing in
        guard existing.supersedingKey == supersedingKey else { return false }
        pendingBytes -= existing.data.count
        return true
      }
    }

    pending.append(Frame(data: data, supersedingKey: supersedingKey))
    pendingBytes += data.count

    if pendingBytes > Self.maxBacklogBytes {
      // Not a write failure, so nothing else will report it: say so before dropping the
      // client, or a disconnect this daemon *chose* reads afterwards as one it suffered.
      let notice =
        "graphcoded: outbound backlog \(pendingBytes)B exceeded on fd \(fileDescriptor)"
        + " — dropping a client that stopped reading\n"
      FileHandle.standardError.write(Data(notice.utf8))
      beginClosingLocked()
    }

    condition.signal()
    return true
  }

  /// Stops the writer and returns only once it is no longer touching the descriptor, so
  /// the caller can close it safely.
  ///
  /// The wait is what makes the descriptor's ownership single. Closing it while a write
  /// is in flight would free a number the kernel is free to hand straight to the next
  /// `accept`, and the reader still blocked on it would then be reading someone else's
  /// connection. The wait is bounded because `beginClosingLocked` shuts the socket down,
  /// which makes a write parked on a wedged peer fail rather than wait.
  func closeAndWait() {
    condition.lock()
    beginClosingLocked()
    condition.broadcast()
    while !isFinished {
      condition.wait()
    }
    condition.unlock()
  }

  private func beginClosingLocked() {
    guard !isClosing else { return }
    isClosing = true
    pending.removeAll()
    pendingBytes = 0
    // A writer parked inside `write(2)` on a wedged peer will not notice a flag, and
    // neither will the connection loop's reader. Tearing the socket down makes both
    // return, which is how a client this daemon gives up on is actually let go.
    shutdown(fileDescriptor, SHUT_RDWR)
  }

  /// Never closes the descriptor: `closeAndWait`'s caller owns that, and only once this
  /// has stopped.
  private func pump() {
    while true {
      condition.lock()
      while pending.isEmpty && !isClosing {
        condition.wait()
      }
      if isClosing {
        condition.unlock()
        break
      }
      let frame = pending.removeFirst()
      pendingBytes -= frame.data.count
      condition.unlock()

      do {
        try FramedMessageIO.writeFrame(frame.data, to: fileDescriptor)
      } catch {
        // The peer is gone. Shut the socket down so the connection loop's reader stops
        // waiting on it too, rather than holding the connection open on one live half.
        condition.lock()
        beginClosingLocked()
        condition.unlock()
        break
      }
    }
    condition.lock()
    isFinished = true
    condition.broadcast()
    condition.unlock()
  }
}

/// The POSIX `close(2)`, named so it cannot be confused with — or silently resolve to —
/// the `close()` members either type above declares.
private func posixClose(_ fileDescriptor: Int32) {
  #if canImport(Darwin)
    _ = Darwin.close(fileDescriptor)
  #else
    _ = Glibc.close(fileDescriptor)
  #endif
}

/// Every open client connection's outbound half, keyed by descriptor.
///
/// A registry rather than a channel handed around because the daemon writes to a client
/// from three places that know nothing of one another — `GraphStore` broadcasting,
/// `ProjectRegistry` answering, and the version-skew reply in `graphcoded`'s connection
/// loop — and all three hold only the descriptor.
public enum OutboundChannels {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var channels: [Int32: OutboundChannel] = [:]

  /// Called once per accepted connection, before anything writes to it.
  public static func open(_ fileDescriptor: Int32) {
    lock.lock()
    let stale = channels.removeValue(forKey: fileDescriptor)
    channels[fileDescriptor] = OutboundChannel(fileDescriptor: fileDescriptor)
    lock.unlock()
    // A descriptor number the kernel reused before its previous channel was torn down.
    // Stopped outside the registry lock: `closeAndWait` waits on a writer thread, and
    // holding the table while it does would stall every other connection's sends.
    stale?.closeAndWait()
  }

  /// Queues a frame for a client without blocking. `supersedingKey` replaces an
  /// undelivered frame carrying the same key — see `OutboundChannel.send`.
  ///
  /// Returns `false` when there is no live channel for the descriptor, which is what
  /// tells a broadcaster to forget the connection.
  @discardableResult
  public static func send(
    _ data: Data, to fileDescriptor: Int32, supersedingKey: String? = nil
  ) -> Bool {
    lock.lock()
    let channel = channels[fileDescriptor]
    lock.unlock()
    guard let channel else { return false }
    return channel.send(data, supersedingKey: supersedingKey)
  }

  /// Closes the connection's outbound half and releases its descriptor. Takes over the
  /// `close(2)` the connection loop used to perform itself, so the descriptor outlives
  /// any write still in flight on it.
  public static func close(_ fileDescriptor: Int32) {
    lock.lock()
    let channel = channels.removeValue(forKey: fileDescriptor)
    lock.unlock()
    // Stop the writer before closing, never after: the wait is what guarantees nothing is
    // inside a `write` on a descriptor number about to be handed to the next `accept`.
    channel?.closeAndWait()
    posixClose(fileDescriptor)
  }
}
