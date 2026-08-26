import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

/// Length-prefixed framing over a raw socket file descriptor or a bounded byte stream —
/// a 4-byte big-endian
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
///
/// The stream-based overloads below hold the same invariant a different way: every
/// `DaemonConnection` writes through its own serial queue, so the lock table applies
/// only to the descriptor-based path.
public enum FramedMessageIO {
  public static let v2MaxPayloadBytes = Int(DaemonFrameHeader.maxPayloadBytes)
  public static let legacyMaxPayloadBytes = Int(DaemonFrameHeader.legacySafetyCeilingBytes)
  public static let maxPayloadBytes = v2MaxPayloadBytes

  public enum IOError: Error, Equatable {
    case connectionClosed
    case readFailed(errno: Int32)
    case writeFailed(errno: Int32)
    case invalidHeader
    case payloadTooLarge
  }

  #if canImport(Darwin) || canImport(Glibc)
    public static func writeFrame(
      _ data: Data,
      to fileDescriptor: Int32,
      maxPayloadBytes: Int = legacyMaxPayloadBytes
    ) throws {
      let lock = writeLocks.lock(forDescriptor: fileDescriptor)
      lock.lock()
      defer { lock.unlock() }

      guard let limit = UInt32(exactly: maxPayloadBytes) else {
        throw IOError.payloadTooLarge
      }
      let header: Data
      do {
        header = try DaemonFrameHeader.encodeLength(
          data.count, maxPayloadBytes: limit)
      } catch {
        throw IOError.payloadTooLarge
      }
      try writeAll(header, to: fileDescriptor)
      try writeAll(data, to: fileDescriptor)
    }

    public static func readFrame(
      from fileDescriptor: Int32,
      maxPayloadBytes: Int = legacyMaxPayloadBytes
    ) throws -> Data {
      guard let limit = UInt32(exactly: maxPayloadBytes) else {
        throw IOError.payloadTooLarge
      }
      let header = try readExactly(DaemonFrameHeader.byteCount, from: fileDescriptor)
      let length: Int
      do {
        length = try DaemonFrameHeader.decodeLength(
          Array(header), maxPayloadBytes: limit)
      } catch DaemonFrameHeader.HeaderError.invalidHeader {
        throw IOError.invalidHeader
      } catch {
        throw IOError.payloadTooLarge
      }
      return length == 0 ? Data() : try readExactly(length, from: fileDescriptor)
    }
  #endif

  /// The transport-independent path used by named pipes, TCP, and test streams.
  /// Exact operations make partial reads and writes an adapter concern rather than
  /// allowing a short operation to be mistaken for a complete frame.
  public static func writeFrame(
    _ data: Data,
    to stream: any DaemonByteStream,
    maxPayloadBytes: Int = legacyMaxPayloadBytes
  ) async throws {
    guard let limit = UInt32(exactly: maxPayloadBytes) else {
      throw IOError.payloadTooLarge
    }
    let header: Data
    do {
      header = try DaemonFrameHeader.encodeLength(
        data.count, maxPayloadBytes: limit)
    } catch {
      throw IOError.payloadTooLarge
    }
    try await stream.writeAll(header)
    if !data.isEmpty {
      try await stream.writeAll(data)
    }
  }

  public static func readFrame(
    from stream: any DaemonByteStream,
    maxPayloadBytes: Int = legacyMaxPayloadBytes
  ) async throws -> Data {
    guard let limit = UInt32(exactly: maxPayloadBytes) else {
      throw IOError.payloadTooLarge
    }
    let header = try await stream.readExactly(DaemonFrameHeader.byteCount)
    let length: Int
    do {
      length = try DaemonFrameHeader.decodeLength(
        Array(header), maxPayloadBytes: limit)
    } catch DaemonFrameHeader.HeaderError.invalidHeader {
      throw IOError.invalidHeader
    } catch {
      throw IOError.payloadTooLarge
    }
    return length == 0 ? Data() : try await stream.readExactly(length)
  }

  #if canImport(Darwin) || canImport(Glibc)
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
        guard let baseAddress = rawBuffer.baseAddress else { return }
        var remaining = rawBuffer.count
        var pointer = baseAddress
        while remaining > 0 {
          let written = write(fileDescriptor, pointer, remaining)
          if written < 0, errno == EINTR { continue }
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
          read(
            fileDescriptor, rawBuffer.baseAddress!.advanced(by: totalRead),
            count - totalRead)
        }
        if bytesRead == 0 { throw IOError.connectionClosed }
        if bytesRead < 0, errno == EINTR { continue }
        if bytesRead < 0 { throw IOError.readFailed(errno: errno) }
        totalRead += bytesRead
      }
      return Data(buffer)
    }
  #endif
}
