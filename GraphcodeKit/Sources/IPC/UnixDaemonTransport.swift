import Foundation

#if canImport(Darwin)
  import Darwin

  /// A small async adapter around a Unix descriptor. Blocking syscalls are moved off
  /// Swift's cooperative executor; socket receive/send timeouts bound stalled peers.
  public final class UnixSocketByteStream: @unchecked Sendable, DaemonByteStream {
    private let fileDescriptor: Int32
    private let closeOnClose: Bool
    private let lock = NSLock()
    private var isClosed = false

    public init(
      fileDescriptor: Int32,
      readTimeout: TimeInterval? = nil,
      writeTimeout: TimeInterval? = nil,
      closeOnClose: Bool = true
    ) {
      self.fileDescriptor = fileDescriptor
      self.closeOnClose = closeOnClose
      Self.applyTimeout(readTimeout, to: fileDescriptor, option: SO_RCVTIMEO)
      Self.applyTimeout(writeTimeout, to: fileDescriptor, option: SO_SNDTIMEO)
      var noSignal = 1
      _ = setsockopt(
        fileDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
        socklen_t(MemoryLayout<Int32>.size))
    }

    public func readExactly(_ count: Int) async throws -> Data {
      try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global().async {
          do {
            continuation.resume(returning: try Self.read(count, from: self.fileDescriptor))
          } catch {
            continuation.resume(throwing: error)
          }
        }
      }
    }

    public func writeAll(_ data: Data) async throws {
      try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global().async {
          do {
            try Self.write(data, to: self.fileDescriptor)
            continuation.resume()
          } catch {
            continuation.resume(throwing: error)
          }
        }
      }
    }

    public func close() async throws {
      closeSync()
    }

    public func setReadTimeout(_ timeout: TimeInterval?) {
      Self.applyTimeout(timeout, to: fileDescriptor, option: SO_RCVTIMEO)
    }

    public func closeSync() {
      lock.lock()
      let shouldClose = !isClosed
      isClosed = true
      lock.unlock()
      if shouldClose, closeOnClose {
        Darwin.close(fileDescriptor)
      }
    }

    fileprivate func readExactlySync(_ count: Int) throws -> Data {
      try Self.read(count, from: fileDescriptor)
    }

    fileprivate func writeFrameSync(_ data: Data) throws {
      try FramedMessageIO.writeFrame(data, to: fileDescriptor)
    }

    private static func applyTimeout(
      _ timeout: TimeInterval?, to fileDescriptor: Int32, option: Int32
    ) {
      var interval = timeval(tv_sec: 0, tv_usec: 0)
      if let timeout, timeout.isFinite, timeout >= 0 {
        interval = timeval(
          tv_sec: Int(timeout),
          tv_usec: Int32((timeout - timeout.rounded(.down)) * 1_000_000))
      }
      _ = setsockopt(
        fileDescriptor, SOL_SOCKET, option, &interval,
        socklen_t(MemoryLayout<timeval>.size))
    }

    private static func write(_ data: Data, to fileDescriptor: Int32) throws {
      try data.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) in
        guard let baseAddress = rawBuffer.baseAddress else { return }
        var remaining = rawBuffer.count
        var pointer = baseAddress
        while remaining > 0 {
          let result = Darwin.write(fileDescriptor, pointer, remaining)
          if result < 0, errno == EINTR { continue }
          if result <= 0 {
            throw FramedMessageIO.IOError.writeFailed(errno: errno)
          }
          remaining -= result
          pointer = pointer.advanced(by: result)
        }
      }
    }

    private static func read(_ count: Int, from fileDescriptor: Int32) throws -> Data {
      guard count > 0 else { return Data() }
      var buffer = [UInt8](repeating: 0, count: count)
      var total = 0
      while total < count {
        let result = buffer.withUnsafeMutableBytes { rawBuffer in
          Darwin.read(
            fileDescriptor, rawBuffer.baseAddress!.advanced(by: total), count - total)
        }
        if result == 0 { throw FramedMessageIO.IOError.connectionClosed }
        if result < 0, errno == EINTR { continue }
        if result < 0 {
          throw FramedMessageIO.IOError.readFailed(errno: errno)
        }
        total += result
      }
      return Data(buffer)
    }
  }

  /// Unix-domain socket implementation of the portable connection contract.
  public final class UnixSocketConnection: @unchecked Sendable, DaemonConnection {
    public let id: UUID
    public let endpoint: DaemonEndpoint
    private let stream: UnixSocketByteStream
    private let writeQueue = DispatchQueue(
      label: "com.graphcode.unix-socket-frame-writes")

    public init(
      id: UUID = UUID(),
      fileDescriptor: Int32,
      endpoint: DaemonEndpoint = .unixSocket(URL(fileURLWithPath: "")),
      readTimeout: TimeInterval? = nil,
      writeTimeout: TimeInterval? = nil
    ) {
      self.id = id
      self.endpoint = endpoint
      self.stream = UnixSocketByteStream(
        fileDescriptor: fileDescriptor,
        readTimeout: readTimeout,
        writeTimeout: writeTimeout)
    }

    public func receiveFrame() async throws -> Data {
      try await FramedMessageIO.readFrame(from: stream)
    }

    public func sendFrame(_ data: Data) async throws {
      try await withCheckedThrowingContinuation { continuation in
        writeQueue.async {
          do {
            try self.stream.writeFrameSync(data)
            continuation.resume()
          } catch {
            continuation.resume(throwing: error)
          }
        }
      }
    }

    public func receiveFrameSync() throws -> Data {
      let header = try stream.readExactlySync(DaemonFrameHeader.byteCount)
      let length = try DaemonFrameHeader.decodeLength(Array(header))
      return length == 0 ? Data() : try stream.readExactlySync(length)
    }

    public func sendFrameSync(_ data: Data) throws {
      try writeQueue.sync {
        try stream.writeFrameSync(data)
      }
    }

    public func close() async throws {
      writeQueue.sync {
        stream.closeSync()
      }
    }

    public func closeSync() {
      writeQueue.sync {
        stream.closeSync()
      }
    }

    public func setReadTimeout(_ timeout: TimeInterval?) {
      stream.setReadTimeout(timeout)
    }
  }

  /// Listener adapter used by the macOS daemon. The bind/unlink policy remains owned by
  /// the daemon process; this type owns only the descriptor and accept loop.
  public final class UnixSocketListener: @unchecked Sendable, DaemonListener {
    public let endpoint: DaemonEndpoint
    private let fileDescriptor: Int32
    private let path: String
    private let lock = NSLock()
    private var isClosed = false

    public init(path: URL, backlog: Int32 = 8) throws {
      let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
      guard descriptor >= 0 else {
        throw FramedMessageIO.IOError.readFailed(errno: errno)
      }
      self.fileDescriptor = descriptor
      self.path = path.path
      self.endpoint = .unixSocket(path)

      var address = sockaddr_un()
      address.sun_family = sa_family_t(AF_UNIX)
      address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
      guard self.path.utf8.count < MemoryLayout<sockaddr_un>.size - 2 else {
        Darwin.close(descriptor)
        throw FramedMessageIO.IOError.writeFailed(errno: ENAMETOOLONG)
      }
      withUnsafeMutablePointer(to: &address.sun_path) { field in
        field.withMemoryRebound(
          to: CChar.self, capacity: MemoryLayout.size(ofValue: field.pointee)
        ) { pointer in
          self.path.withCString {
            strncpy(pointer, $0, MemoryLayout.size(ofValue: field.pointee) - 1)
          }
        }
      }
      let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
      }
      guard bound == 0 else {
        let code = errno
        Darwin.close(descriptor)
        throw FramedMessageIO.IOError.writeFailed(errno: code)
      }
      guard Darwin.listen(descriptor, backlog) == 0 else {
        let code = errno
        Darwin.close(descriptor)
        unlink(self.path)
        throw FramedMessageIO.IOError.writeFailed(errno: code)
      }
    }

    public func accept() async throws -> any DaemonConnection {
      try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global().async {
          let client = Darwin.accept(self.fileDescriptor, nil, nil)
          guard client >= 0 else {
            continuation.resume(throwing: FramedMessageIO.IOError.readFailed(errno: errno))
            return
          }
          continuation.resume(
            returning: UnixSocketConnection(
              fileDescriptor: client, endpoint: self.endpoint))
        }
      }
    }

    public func close() async throws {
      lock.lock()
      let shouldClose = !isClosed
      isClosed = true
      lock.unlock()
      if shouldClose {
        Darwin.close(fileDescriptor)
        unlink(path)
      }
    }
  }
#endif
