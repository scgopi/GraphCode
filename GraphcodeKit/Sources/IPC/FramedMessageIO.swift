import Foundation

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

/// Length-prefixed framing over a raw socket file descriptor — a 4-byte big-endian
/// length header followed by that many bytes of JSON. Shared by `graphcoded`'s
/// connection handlers and the app's `OrchestratorClient` so both sides always agree
/// on where one message ends and the next begins.
///
/// Blocking, on purpose: every call site runs this on a background thread/queue
/// dedicated to one connection, not the main thread, so blocking `read`/`write` is the
/// simplest correct thing here — no need for `Network.framework` or a custom
/// `DispatchIO` setup at this scale (a handful of local connections).
public enum FramedMessageIO {
  public enum IOError: Error, Equatable {
    case connectionClosed
    case readFailed(errno: Int32)
    case writeFailed(errno: Int32)
  }

  public static func writeFrame(_ data: Data, to fileDescriptor: Int32) throws {
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
