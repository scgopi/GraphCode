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
  /// A safety valve rather than a working limit: reaching it means a peer stopped reading
  /// and stayed stopped across many changes. Disconnecting it is the honest outcome — it
  /// is already arbitrarily far behind, and the graph it would eventually receive is one
  /// the daemon has long since replaced.
  ///
  /// Sized for the backlog a *healthy* client can legitimately carry. Supersession keeps
  /// each graph to one undelivered snapshot, but the keys are per graph, so a client
  /// joined to many projects can hold one of each at once — the budget has to clear that
  /// comfortably, or the fix for cross-project supersession would start disconnecting the
  /// very clients it exists to serve.
  static let maxBacklogBytes = 4 * 1024 * 1024

  private struct Frame {
    let data: Data
    /// Frames sharing a key supersede one another while undelivered — see `send`.
    let supersedingKey: String?
  }

  private let fileDescriptor: Int32
  private let backlogBudget: Int
  /// Whether the descriptor takes socket calls. `send(2)` and `poll`-for-writability are
  /// how a socket is written without blocking, and they are meaningless on anything else —
  /// tests hand these stores a `/dev/null`, where `send` fails outright with `ENOTSOCK`.
  /// A non-socket cannot block a writer the way a peer that stopped reading can, so a
  /// plain `write` is both correct and sufficient there.
  private let isSocket: Bool
  private let condition = NSCondition()
  private var pending: [Frame] = []
  private var pendingBytes = 0
  private var isClosing = false
  private var isFinished = false

  /// `backlogBudget` is injectable so tests can exercise the valve without moving
  /// megabytes through a socket to reach it.
  init(fileDescriptor: Int32, backlogBudget: Int = OutboundChannel.maxBacklogBytes) {
    self.fileDescriptor = fileDescriptor
    self.backlogBudget = backlogBudget
    var socketType: Int32 = 0
    var typeSize = socklen_t(MemoryLayout<Int32>.size)
    isSocket =
      getsockopt(fileDescriptor, SOL_SOCKET, SO_TYPE, &socketType, &typeSize) == 0
    Self.armAgainstSIGPIPE(fileDescriptor)
    // Captured strongly on purpose: the channel must outlive the registry's reference to
    // it, because the descriptor is closed by `pump` on its way out. A weak capture would
    // let a channel released without `close()` take its thread — and its unclosed
    // descriptor — with it.
    let thread = Thread { [self] in pump() }
    thread.name = "graphcoded.outbound.\(fileDescriptor)"
    // Matches the callers it serves. A writer left at the default class is a priority
    // inversion waiting to happen: `closeAndWait` blocks the disconnecting thread on this
    // one, and answering a client's command is interactive work whoever is waiting on it.
    thread.qualityOfService = .userInitiated
    thread.start()
  }

  /// Writing to a socket whose peer has gone — or one this channel has just shut down on
  /// its way out — otherwise raises `SIGPIPE`, and the default action kills the process.
  /// The channel arms the descriptor itself rather than trusting whoever handed it over:
  /// `graphcoded` does set this on the sockets it accepts, but a writer that only survives
  /// because its caller remembered is a crash waiting for the one caller that does not.
  private static func armAgainstSIGPIPE(_ fileDescriptor: Int32) {
    #if canImport(Darwin)
      var enabled: Int32 = 1
      setsockopt(
        fileDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
    #else
      // Linux has no per-socket SO_NOSIGPIPE; ignoring it process-wide is the equivalent
      // armour, and makes the write return EPIPE the error path already handles.
      signal(SIGPIPE, SIG_IGN)
    #endif
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

    // The frame just queued is excluded from the measurement, so a single frame is always
    // allowed however large it is. Measuring the whole queue meant one oversized snapshot
    // tripped the valve on its own, which would disconnect a perfectly healthy reader for
    // the crime of opening a big graph — and the bigger the graph grew, the more certain
    // it became that nobody could open it at all. What the budget is for is a *backlog*:
    // frames piling up behind a peer that has stopped reading.
    if pendingBytes - data.count > backlogBudget {
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

  /// Whether this channel can still carry frames. A channel goes dead when its write
  /// failed or its backlog budget ran out, and a dead one must never be left standing in
  /// the registry: the next connection to be handed the same descriptor number would
  /// inherit it and find every send refused.
  var isAlive: Bool {
    condition.lock()
    defer { condition.unlock() }
    return !isClosing && !isFinished
  }

  /// Gives up the descriptor without touching it: stops accepting frames, drops the
  /// backlog, and lets the writer thread retire on its own.
  ///
  /// For a channel whose descriptor number has already been taken over by a new
  /// connection. `closeAndWait` would be wrong there — its `shutdown` would tear down the
  /// *new* connection now answering to that number.
  func detach() {
    condition.lock()
    isClosing = true
    pending.removeAll()
    pendingBytes = 0
    condition.broadcast()
    condition.unlock()
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
    // `Int32(…)` because Glibc imports `SHUT_RDWR` as `Int` where Darwin gives `Int32`;
    // without the conversion this compiles on macOS and fails the Linux build.
    shutdown(fileDescriptor, Int32(SHUT_RDWR))
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

      if !writeFrame(frame.data) {
        // Either the peer is gone or we were asked to stop. Shut the socket down so the
        // connection loop's reader stops waiting on it too, rather than holding the
        // connection open on one live half.
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

  private var shouldStop: Bool {
    condition.lock()
    defer { condition.unlock() }
    return isClosing
  }

  /// Short enough that closing a channel whose peer stopped reading is prompt, long
  /// enough that a healthy slow reader costs no measurable spinning.
  private static let writabilityPollMilliseconds: Int32 = 50

  /// Writes one length-prefixed frame, returning false if the peer failed or the channel
  /// was closed part-way through.
  ///
  /// Every write is non-blocking *per call* (`MSG_DONTWAIT`), waiting for writability
  /// with a bounded `poll` rather than parking inside `write(2)` until the peer drains.
  /// That is not a refinement, it is what lets `closeAndWait` promise to return: a thread
  /// already blocked inside a write on a unix socket is **not** reliably woken by another
  /// thread's `shutdown`, so a wedged peer could hang the disconnecting caller for ever —
  /// the original bug moved one layer down, where it showed up as the full test suite
  /// hanging on a channel whose client never read. Polling in slices lets the writer
  /// notice `isClosing` by itself instead of depending on being interrupted.
  ///
  /// `MSG_DONTWAIT` per call rather than `O_NONBLOCK` on the descriptor: that flag lives
  /// on the open file description, which the daemon's *reader* shares, and a reader that
  /// started returning `EAGAIN` would tear down every connection.
  private func writeFrame(_ data: Data) -> Bool {
    let length = UInt32(data.count)
    var buffer = Data(capacity: 4 + data.count)
    buffer.append(UInt8((length >> 24) & 0xff))
    buffer.append(UInt8((length >> 16) & 0xff))
    buffer.append(UInt8((length >> 8) & 0xff))
    buffer.append(UInt8(length & 0xff))
    buffer.append(data)

    return buffer.withUnsafeBytes { raw -> Bool in
      var remaining = raw.count
      var pointer = raw.baseAddress!
      while remaining > 0 {
        if shouldStop { return false }
        let written: Int
        if isSocket {
          #if canImport(Darwin)
            written = Darwin.send(fileDescriptor, pointer, remaining, MSG_DONTWAIT)
          #else
            written = Glibc.send(fileDescriptor, pointer, remaining, Int32(MSG_DONTWAIT))
          #endif
        } else {
          written = write(fileDescriptor, pointer, remaining)
        }
        if written > 0 {
          remaining -= written
          pointer = pointer.advanced(by: written)
          continue
        }
        if written < 0 && errno == EINTR { continue }
        guard written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) else { return false }
        // The peer's buffer is full. Wait for room in slices, so a close is noticed
        // promptly even when the peer never reads again.
        var descriptor = pollfd(fd: fileDescriptor, events: Int16(POLLOUT), revents: 0)
        let ready = poll(&descriptor, 1, Self.writabilityPollMilliseconds)
        if ready < 0 && errno != EINTR { return false }
        if ready > 0 && descriptor.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 {
          return false
        }
      }
      return true
    }
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

  /// Ensures the descriptor has a live channel — called wherever a connection is
  /// registered.
  ///
  /// Idempotent, because a connection is registered more than once on its way in: the
  /// daemon's registry records it, then each project's store records it again as the
  /// client joins. Replacing a live channel on the second call would throw away whatever
  /// the first had already queued, so an existing live one is kept.
  ///
  /// A *dead* channel is replaced. Descriptor numbers are recycled aggressively, so a
  /// channel whose write failed can outlive its connection and be inherited by the next
  /// one to be given that number — which would then find every send refused and be
  /// dropped as disconnected the moment it arrived.
  /// `backlogBudget` is `nil` for the standard budget; tests inject a small one so the
  /// valve can be exercised without moving megabytes through a socket.
  public static func open(_ fileDescriptor: Int32, backlogBudget: Int? = nil) {
    lock.lock()
    let existing = channels[fileDescriptor]
    guard existing?.isAlive != true else {
      lock.unlock()
      return
    }
    channels[fileDescriptor] = OutboundChannel(
      fileDescriptor: fileDescriptor,
      backlogBudget: backlogBudget ?? OutboundChannel.maxBacklogBytes)
    lock.unlock()
    // Detached rather than closed: the number belongs to the connection being opened
    // here, so shutting it down would tear that one down.
    existing?.detach()
  }

  /// Queues a frame for a client without blocking. `supersedingKey` replaces an
  /// undelivered frame carrying the same key — see `OutboundChannel.send`.
  ///
  /// Returns `false` when the descriptor has no live channel — it was never registered,
  /// or its channel has failed. That is what tells a broadcaster to forget the
  /// connection: the same signal a failed write used to give synchronously, now arriving
  /// on the send after the failure rather than during it.
  ///
  /// An unregistered descriptor is refused rather than given a channel of its own.
  /// Creating one here looks like insurance against losing a frame, and is the opposite:
  /// descriptor numbers are recycled, so a send arriving after its connection closed
  /// would mint a channel on a number the kernel has already reassigned and hand the
  /// departed connection's frame to whoever holds it now. Registration is what makes a
  /// descriptor writable, and both `addConnection` paths open a channel as they register.
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
    // Only the registry's own channel owns a descriptor, so with no channel there is
    // nothing here to close. Closing anyway would shut a number this registry never had —
    // and by the second call that number belongs to somebody else.
    guard let channel else { return }
    // Stop the writer before closing, never after: the wait is what guarantees nothing is
    // inside a `write` on a descriptor number about to be handed to the next `accept`.
    channel.closeAndWait()
    posixClose(fileDescriptor)
  }
}
