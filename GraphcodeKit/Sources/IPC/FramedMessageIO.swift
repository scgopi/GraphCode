import Foundation

#if canImport(Darwin)
  import Darwin
#endif

/// Length-prefixed framing over a raw socket file descriptor — a 4-byte big-endian
/// length header followed by that many bytes of JSON. Shared by `graphcoded`'s
/// connection handlers and the app's `OrchestratorClient` so both sides always agree
/// on where one message ends and the next begins.
///
/// Blocking, on purpose: every call site runs this on a background thread/queue, not the
/// main thread, so blocking `read`/`write` is the simplest correct thing here — no need
/// for `Network.framework` or a custom `DispatchIO` setup at this scale (a handful of
/// local connections).
///
/// Writes are serialized per descriptor, which is not a detail: a frame goes out as two
/// `write` calls, and *nothing* in this codebase gives a connection a single writer. The
/// app sends every command from `DispatchQueue.global()`; the daemon answers from two
/// separate actors (`ProjectRegistry`, `GraphStore`) plus the version-skew reply in
/// `graphcoded/main.swift`. Two of those overlapping on one socket puts header A in front
/// of body B, and the reader — having consumed a length that belongs to someone else's
/// message — is wrong from that byte onward. That is what "unrecognized command —
/// graphcoded may be older than the client that sent it" was really reporting when a new
/// workspace opened (0.1.46-beta1): its three launch commands wait together on the
/// just-bootstrapped daemon and are released at the same instant.
public enum FramedMessageIO {
  public enum IOError: Error, Equatable {
    case connectionClosed
    case readFailed(errno: Int32)
    case writeFailed(errno: Int32)
  }

  public static func writeFrame(_ data: Data, to fileDescriptor: Int32) throws {
    let lock = writeLocks.lock(forDescriptor: fileDescriptor)
    lock.lock()
    defer { lock.unlock() }

    let length = UInt32(data.count)
    let header: [UInt8] = [
      UInt8((length >> 24) & 0xff),
      UInt8((length >> 16) & 0xff),
      UInt8((length >> 8) & 0xff),
      UInt8(length & 0xff),
    ]
    try writeAll(Data(header), to: fileDescriptor)
    try writeAll(data, to: fileDescriptor)
  }

  public static func readFrame(from fileDescriptor: Int32) throws -> Data {
    let header = try readExactly(4, from: fileDescriptor)
    let length =
      (UInt32(header[header.startIndex]) << 24)
      | (UInt32(header[header.startIndex + 1]) << 16)
      | (UInt32(header[header.startIndex + 2]) << 8)
      | UInt32(header[header.startIndex + 3])
    return try readExactly(Int(length), from: fileDescriptor)
  }

  /// One lock per descriptor rather than one for the whole process: a write blocks while
  /// its socket buffer is full, and the daemon broadcasts to every connected client — a
  /// single lock would let one wedged client stall the writes to all the others.
  ///
  /// Locks are kept rather than reclaimed on close. Descriptor numbers are small and the
  /// kernel reuses them, so the table stays about as large as the peak connection count,
  /// and a reused number simply gets the same lock back — correct either way, where
  /// discarding one a concurrent writer still holds would not be.
  private static let writeLocks = DescriptorLocks()

  private final class DescriptorLocks: @unchecked Sendable {
    private var locks: [Int32: NSLock] = [:]
    private let tableLock = NSLock()

    func lock(forDescriptor descriptor: Int32) -> NSLock {
      tableLock.lock()
      defer { tableLock.unlock() }
      if let existing = locks[descriptor] { return existing }
      let created = NSLock()
      locks[descriptor] = created
      return created
    }
  }

  private static func writeAll(_ data: Data, to fileDescriptor: Int32) throws {
    try data.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) in
      var remaining = rawBuffer.count
      var pointer = rawBuffer.baseAddress!
      while remaining > 0 {
        let written = write(fileDescriptor, pointer, remaining)
        if written <= 0 {
          throw IOError.writeFailed(errno: errno)
        }
        remaining -= written
        pointer = pointer.advanced(by: written)
      }
    }
  }

  private static func readExactly(_ count: Int, from fileDescriptor: Int32) throws -> Data {
    guard count > 0 else { return Data() }
    var buffer = [UInt8](repeating: 0, count: count)
    var totalRead = 0
    while totalRead < count {
      let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
        read(fileDescriptor, rawBuffer.baseAddress!.advanced(by: totalRead), count - totalRead)
      }
      if bytesRead == 0 { throw IOError.connectionClosed }
      if bytesRead < 0 { throw IOError.readFailed(errno: errno) }
      totalRead += bytesRead
    }
    return Data(buffer)
  }
}
