import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

/// Length-prefixed framing over a bounded byte stream: a four-byte big-endian
/// length header followed by that many bytes of JSON.
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
