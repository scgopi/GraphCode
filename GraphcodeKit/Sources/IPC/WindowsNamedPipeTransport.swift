import Foundation

#if os(Windows)
  import WinSDK

  /// Errors raised by the Windows daemon transport. Win32 status values are kept
  /// intact so callers can distinguish an unavailable daemon from a cancelled
  /// operation without parsing localized text.
  public enum WindowsPipeError: Error, Equatable, Sendable {
    case win32(operation: String, code: UInt32)
    case connectionClosed
    case timedOut
    case invalidFrame
    case serverIdentityRejected
    case instanceAlreadyRunning
  }

  private final class WindowsPipeHandle: @unchecked Sendable {
    let value: HANDLE

    init(_ value: HANDLE) {
      self.value = value
    }
  }

  private enum WindowsPipeSecurity {
    static func attributes(for sid: String) throws -> (SECURITY_ATTRIBUTES, HLOCAL) {
      let descriptorText = "D:P(A;;GA;;;\(sid))"
      var descriptor: PSECURITY_DESCRIPTOR?
      let success = withWideString(descriptorText) { text in
        ConvertStringSecurityDescriptorToSecurityDescriptorW(
          text,
          DWORD(SDDL_REVISION_1),
          &descriptor,
          nil)
      }
      guard success != false, let descriptor else {
        throw WindowsPipeError.win32(
          operation: "ConvertStringSecurityDescriptorToSecurityDescriptorW",
          code: GetLastError())
      }
      let attributes = SECURITY_ATTRIBUTES(
        nLength: DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size),
        lpSecurityDescriptor: descriptor,
        bInheritHandle: false)
      return (attributes, HLOCAL(descriptor))
    }
  }

  private enum WindowsNamedPipeIdentity {
    static func values(
      environment: [String: String],
      homeDirectory: URL
    ) throws -> (sid: String, supportHash: String) {
      let sid = try WindowsUserIdentity.currentSID()
      let support = SupportDirectory.url(environment: environment, homeDirectory: homeDirectory)
      let supportHash = GraphcodeSHA256.hex(
        Data(support.standardizedFileURL.path.lowercased().utf8))
      return (sid, supportHash)
    }
  }

  /// The SID of the interactive user running graphcode. Named pipes are scoped
  /// by this identity rather than by a username, which is mutable and ambiguous
  /// in domain accounts.
  public enum WindowsUserIdentity {
    public static func currentSID() throws -> String {
      var token: HANDLE?
      guard
        OpenProcessToken(
          GetCurrentProcess(),
          DWORD(TOKEN_QUERY),
          &token),
        let token
      else {
        throw WindowsPipeError.win32(operation: "OpenProcessToken", code: GetLastError())
      }
      defer { _ = CloseHandle(token) }

      var required: DWORD = 0
      _ = GetTokenInformation(token, TokenUser, nil, 0, &required)
      guard required > 0 else {
        throw WindowsPipeError.win32(operation: "GetTokenInformation", code: GetLastError())
      }
      let memory = UnsafeMutableRawPointer.allocate(
        byteCount: Int(required), alignment: MemoryLayout<UInt64>.alignment)
      defer { memory.deallocate() }
      guard
        GetTokenInformation(
          token,
          TokenUser,
          memory,
          required,
          &required)
      else {
        throw WindowsPipeError.win32(operation: "GetTokenInformation", code: GetLastError())
      }
      let tokenUser = memory.assumingMemoryBound(to: TOKEN_USER.self).pointee
      var stringSID: LPWSTR?
      guard ConvertSidToStringSidW(tokenUser.User.Sid, &stringSID), let stringSID else {
        throw WindowsPipeError.win32(operation: "ConvertSidToStringSidW", code: GetLastError())
      }
      defer { _ = LocalFree(HLOCAL(stringSID)) }
      return String(decodingCString: stringSID, as: UTF16.self)
    }
  }

  /// A collision-resistant per-user endpoint. The support directory is hashed
  /// so two side-by-side GraphCode installs cannot share a daemon, while the
  /// account SID prevents cross-user collisions and ACL confusion.
  public enum WindowsNamedPipeEndpoint {
    public static func name(
      environment: [String: String] = ProcessInfo.processInfo.environment,
      homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> String {
      if let override = environment.first(where: {
        $0.key.caseInsensitiveCompare(DaemonSocketPath.environmentKey) == .orderedSame
      })?.value.trimmingCharacters(in: .whitespacesAndNewlines),
        override.hasPrefix("\\\\.\\pipe\\")
      {
        return override
      }

      let identity = try WindowsNamedPipeIdentity.values(
        environment: environment, homeDirectory: homeDirectory)
      return "\\\\.\\pipe\\graphcode-\(identity.sid)-\(identity.supportHash.prefix(32))"
    }
  }

  /// A current-user, support-directory-scoped lifetime lock for graphcoded.
  public final class WindowsDaemonInstanceLock: @unchecked Sendable {
    private let handle: HANDLE

    public init(
      environment: [String: String] = ProcessInfo.processInfo.environment,
      homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws {
      let identity = try WindowsNamedPipeIdentity.values(
        environment: environment, homeDirectory: homeDirectory)
      let name = Self.name(
        sid: identity.sid, supportHash: identity.supportHash)
      let securityResult = try WindowsPipeSecurity.attributes(for: identity.sid)
      var security = securityResult.0
      defer { _ = LocalFree(securityResult.1) }

      guard
        let mutex = withWideString(
          name,
          { wideName in CreateMutexW(&security, true, wideName) })
      else {
        throw WindowsPipeError.win32(
          operation: "CreateMutexW", code: GetLastError())
      }
      let error = GetLastError()
      guard error != ERROR_ALREADY_EXISTS else {
        _ = CloseHandle(mutex)
        throw WindowsPipeError.instanceAlreadyRunning
      }
      handle = mutex
    }

    deinit {
      _ = CloseHandle(handle)
    }

    static func name(sid: String, supportHash: String) -> String {
      "Local\\graphcode-daemon-\(sid)-\(supportHash.prefix(32))"
    }
  }

  private func withWideString<Result>(
    _ value: String,
    _ body: (UnsafePointer<WCHAR>) throws -> Result
  ) rethrows -> Result {
    var buffer = Array(value.utf16)
    buffer.append(0)
    return try buffer.withUnsafeBufferPointer { pointer in
      try body(pointer.baseAddress!)
    }
  }

  private func checkPipeHandle(_ handle: HANDLE?, operation: String) throws -> HANDLE {
    guard let handle, handle != INVALID_HANDLE_VALUE else {
      throw WindowsPipeError.win32(operation: operation, code: GetLastError())
    }
    return handle
  }

  private func makePipe(
    name: String,
    userSID: String,
    maxInstances: DWORD
  ) throws -> HANDLE {
    let securityResult = try WindowsPipeSecurity.attributes(for: userSID)
    var security = securityResult.0
    defer { _ = LocalFree(securityResult.1) }
    return try withWideString(name) { wideName in
      try checkPipeHandle(
        CreateNamedPipeW(
          wideName,
          DWORD(PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED),
          DWORD(PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT),
          maxInstances,
          64 * 1024,
          64 * 1024,
          1_000,
          &security),
        operation: "CreateNamedPipeW")
    }
  }

  private final class WindowsPipeOperation: @unchecked Sendable {
    let handle: HANDLE
    let event: HANDLE

    init(handle: HANDLE) throws {
      guard let event = CreateEventW(nil, true, false, nil) else {
        throw WindowsPipeError.win32(operation: "CreateEventW", code: GetLastError())
      }
      self.handle = handle
      self.event = event
    }

    deinit { _ = CloseHandle(event) }

    func wait(timeout: DWORD = INFINITE) throws {
      let result = WaitForSingleObject(event, timeout)
      if result == WAIT_TIMEOUT {
        throw WindowsPipeError.timedOut
      }
      guard result == WAIT_OBJECT_0 else {
        throw WindowsPipeError.win32(operation: "WaitForSingleObject", code: GetLastError())
      }
    }
  }

  /// Overlapped, cancellable byte stream. Every operation is bounded by an
  /// explicit event and can be cancelled by closing the connection; this avoids
  /// a blocked synchronous ReadFile strand surviving daemon shutdown.
  public final class WindowsNamedPipeByteStream: @unchecked Sendable, DaemonByteStream {
    private let handle: HANDLE
    private let lock = NSCondition()
    private var closed = false
    private var activeOperations = 0

    public init(handle: HANDLE) {
      self.handle = handle
    }

    public func readExactly(_ count: Int) async throws -> Data {
      guard count >= 0 else { throw WindowsPipeError.invalidFrame }
      if count == 0 { return Data() }
      return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          DispatchQueue.global(qos: .utility).async {
            do {
              continuation.resume(returning: try self.readSynchronously(count))
            } catch {
              continuation.resume(throwing: error)
            }
          }
        }
      } onCancel: {
        self.cancelPendingIO()
      }
    }

    public func writeAll(_ data: Data) async throws {
      if data.isEmpty { return }
      try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          DispatchQueue.global(qos: .utility).async {
            do {
              try self.writeSynchronously(data)
              continuation.resume()
            } catch {
              continuation.resume(throwing: error)
            }
          }
        }
      } onCancel: {
        self.cancelPendingIO()
      }
    }

    public func close() async throws {
      closeSynchronously()
    }

    public func closeSynchronously() {
      lock.lock()
      guard !closed else {
        lock.unlock()
        return
      }
      closed = true
      _ = CancelIoEx(handle, nil)
      while activeOperations > 0 {
        lock.wait()
      }
      lock.unlock()
      _ = CloseHandle(handle)
    }

    fileprivate func writeFrameSynchronously(_ data: Data) throws {
      let header = try DaemonFrameHeader.encodeLength(
        data.count,
        maxPayloadBytes: UInt32(DaemonFrameHeader.legacySafetyCeilingBytes))
      try writeSynchronously(header)
      if !data.isEmpty {
        try writeSynchronously(data)
      }
    }

    private func beginOperation() throws {
      lock.lock()
      defer { lock.unlock() }
      guard !closed else { throw WindowsPipeError.connectionClosed }
      activeOperations += 1
    }

    private func endOperation() {
      lock.lock()
      activeOperations -= 1
      if activeOperations == 0 { lock.broadcast() }
      lock.unlock()
    }

    fileprivate func cancelPendingIO() {
      lock.lock()
      let shouldCancel = !closed
      lock.unlock()
      if shouldCancel { _ = CancelIoEx(handle, nil) }
    }

    fileprivate func readSynchronously(_ count: Int, by deadline: Date? = nil) throws -> Data {
      try beginOperation()
      defer { endOperation() }
      var output = Data()
      output.reserveCapacity(count)
      var remaining = count
      while remaining > 0 {
        var chunk = [UInt8](repeating: 0, count: remaining)
        var overlapped = OVERLAPPED()
        let operation = try WindowsPipeOperation(handle: handle)
        overlapped.hEvent = operation.event
        var transferred: DWORD = 0
        let succeeded = chunk.withUnsafeMutableBytes { bytes in
          ReadFile(
            handle,
            bytes.baseAddress,
            DWORD(remaining),
            &transferred,
            &overlapped)
        }
        if !succeeded {
          let code = GetLastError()
          guard code == ERROR_IO_PENDING else {
            if code == ERROR_BROKEN_PIPE || code == ERROR_OPERATION_ABORTED {
              throw WindowsPipeError.connectionClosed
            }
            throw WindowsPipeError.win32(operation: "ReadFile", code: code)
          }
        }
        do {
          let timeout = try remainingTimeout(until: deadline)
          try operation.wait(timeout: timeout)
        } catch WindowsPipeError.timedOut {
          withUnsafeMutablePointer(to: &overlapped) { pending in
            _ = CancelIoEx(handle, pending)
          }
          try? operation.wait()
          var cancelledBytes: DWORD = 0
          _ = GetOverlappedResult(handle, &overlapped, &cancelledBytes, false)
          throw WindowsPipeError.timedOut
        }
        guard GetOverlappedResult(handle, &overlapped, &transferred, false) else {
          let code = GetLastError()
          if code == ERROR_BROKEN_PIPE || code == ERROR_OPERATION_ABORTED {
            throw WindowsPipeError.connectionClosed
          }
          throw WindowsPipeError.win32(operation: "GetOverlappedResult", code: code)
        }
        guard transferred > 0 else { throw WindowsPipeError.connectionClosed }
        output.append(contentsOf: chunk.prefix(Int(transferred)))
        remaining -= Int(transferred)
      }
      return output
    }

    private func remainingTimeout(until deadline: Date?) throws -> DWORD {
      guard let deadline else { return INFINITE }
      let remaining = deadline.timeIntervalSinceNow
      guard remaining > 0 else { throw WindowsPipeError.timedOut }
      return DWORD(min(Double(DWORD.max), max(1, (remaining * 1_000).rounded(.up))))
    }

    private func writeSynchronously(_ data: Data) throws {
      try beginOperation()
      defer { endOperation() }
      var offset = 0
      while offset < data.count {
        var overlapped = OVERLAPPED()
        let operation = try WindowsPipeOperation(handle: handle)
        overlapped.hEvent = operation.event
        var transferred: DWORD = 0
        let succeeded = data.withUnsafeBytes { bytes in
          WriteFile(
            handle,
            bytes.baseAddress!.advanced(by: offset),
            DWORD(data.count - offset),
            &transferred,
            &overlapped)
        }
        if !succeeded {
          let code = GetLastError()
          guard code == ERROR_IO_PENDING else {
            if code == ERROR_BROKEN_PIPE || code == ERROR_OPERATION_ABORTED {
              throw WindowsPipeError.connectionClosed
            }
            throw WindowsPipeError.win32(operation: "WriteFile", code: code)
          }
        }
        try operation.wait()
        guard GetOverlappedResult(handle, &overlapped, &transferred, false) else {
          let code = GetLastError()
          if code == ERROR_BROKEN_PIPE || code == ERROR_OPERATION_ABORTED {
            throw WindowsPipeError.connectionClosed
          }
          throw WindowsPipeError.win32(operation: "GetOverlappedResult", code: code)
        }
        guard transferred > 0 else { throw WindowsPipeError.connectionClosed }
        offset += Int(transferred)
      }
    }
  }

  /// A connected named-pipe endpoint with complete-frame write serialization.
  public final class WindowsNamedPipeConnection: @unchecked Sendable, DaemonConnection {
    public let id: Foundation.UUID
    public let endpoint: DaemonEndpoint
    private let stream: WindowsNamedPipeByteStream
    private let writes = DispatchQueue(label: "com.graphcode.windows-pipe-writes")
    private let stateLock = NSLock()
    private var closed = false

    public init(
      id: Foundation.UUID = Foundation.UUID(),
      handle: HANDLE,
      pipeName: String,
      readTimeout: TimeInterval? = nil
    ) {
      self.id = id
      endpoint = .namedPipe(pipeName)
      stream = WindowsNamedPipeByteStream(handle: handle)
      _ = readTimeout
    }

    public func receiveFrame() async throws -> Data {
      try await FramedMessageIO.readFrame(from: stream)
    }

    public func receiveFrameWithPostHandshakeDeadline(
      _ timeout: TimeInterval = 5
    ) async throws -> Data {
      try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          DispatchQueue.global(qos: .utility).async {
            do {
              continuation.resume(
                returning: try self.receiveFrameWithPostHandshakeDeadlineSynchronously(timeout))
            } catch {
              continuation.resume(throwing: error)
            }
          }
        }
      } onCancel: {
        self.stream.cancelPendingIO()
      }
    }

    private func receiveFrameWithPostHandshakeDeadlineSynchronously(
      _ timeout: TimeInterval
    ) throws -> Data {
      let firstByte = try stream.readSynchronously(1)
      let deadline = Date().addingTimeInterval(max(0, timeout))
      var header = firstByte
      header.append(
        try stream.readSynchronously(DaemonFrameHeader.byteCount - 1, by: deadline))
      let length: Int
      do {
        length = try DaemonFrameHeader.decodeLength(
          Array(header), maxPayloadBytes: DaemonFrameHeader.legacySafetyCeilingBytes)
      } catch DaemonFrameHeader.HeaderError.invalidHeader {
        throw FramedMessageIO.IOError.invalidHeader
      } catch {
        throw FramedMessageIO.IOError.payloadTooLarge
      }
      return length == 0
        ? Data()
        : try stream.readSynchronously(length, by: deadline)
    }

    public func sendFrame(_ data: Data) async throws {
      try await withCheckedThrowingContinuation { continuation in
        writes.async {
          do {
            try self.ensureOpen()
            try self.stream.writeFrameSynchronously(data)
            continuation.resume()
          } catch {
            continuation.resume(throwing: error)
          }
        }
      }
    }

    public func close() async throws {
      closeSynchronously()
    }

    private func closeSynchronously() {
      stateLock.lock()
      guard !closed else {
        stateLock.unlock()
        return
      }
      closed = true
      stateLock.unlock()
      stream.closeSynchronously()
    }

    private func ensureOpen() throws {
      stateLock.lock()
      let isClosed = closed
      stateLock.unlock()
      if isClosed { throw WindowsPipeError.connectionClosed }
    }
  }

  /// Listener that creates one overlapped pipe instance per accept. The ACL is
  /// applied at CreateNamedPipeW time, and every accepted client is checked for
  /// the current-user SID before it is handed to the daemon.
  public final class WindowsNamedPipeListener: @unchecked Sendable, DaemonListener {
    public let endpoint: DaemonEndpoint
    private let name: String
    private let sid: String
    private let lock = NSCondition()
    private var closed = false
    private var pendingHandles: Set<UInt> = []

    public init(
      pipeName: String? = nil,
      backlog: Int = 16
    ) throws {
      _ = backlog
      name = try pipeName ?? WindowsNamedPipeEndpoint.name()
      sid = try WindowsUserIdentity.currentSID()
      endpoint = .namedPipe(name)
    }

    public func accept() async throws -> any DaemonConnection {
      try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          DispatchQueue.global(qos: .utility).async {
            do {
              let handle = try self.makeTrackedPipe()
              do {
                try self.ensureOpen()
                try self.connect(handle)
                try self.ensureOpen()
                try self.verifyClient(handle)
                try self.ensureOpen()
                self.untrack(handle)
                continuation.resume(
                  returning: WindowsNamedPipeConnection(
                    handle: handle,
                    pipeName: self.name))
              } catch {
                self.untrack(handle)
                _ = DisconnectNamedPipe(handle)
                _ = CloseHandle(handle)
                throw error
              }
            } catch {
              continuation.resume(throwing: error)
            }
          }
        }
      } onCancel: {
        self.closePending()
      }
    }

    public func close() async throws {
      closePending()
    }

    private func makeTrackedPipe() throws -> HANDLE {
      lock.lock()
      defer { lock.unlock() }
      guard !closed else {
        throw WindowsPipeError.connectionClosed
      }
      let handle = try makePipe(
        name: name,
        userSID: sid,
        maxInstances: DWORD(PIPE_UNLIMITED_INSTANCES))
      pendingHandles.insert(UInt(bitPattern: handle))
      return handle
    }

    private func untrack(_ handle: HANDLE) {
      lock.lock()
      pendingHandles.remove(UInt(bitPattern: handle))
      lock.unlock()
    }

    private func closePending() {
      lock.lock()
      if closed {
        lock.unlock()
        return
      }
      closed = true
      let handles = pendingHandles
      lock.unlock()
      for raw in handles {
        let handle = HANDLE(bitPattern: raw)
        _ = CancelIoEx(handle, nil)
      }
    }

    private func ensureOpen() throws {
      lock.lock()
      let isClosed = closed
      lock.unlock()
      if isClosed {
        throw WindowsPipeError.connectionClosed
      }
    }

    private func isOpen() -> Bool {
      lock.lock()
      defer { lock.unlock() }
      return !closed
    }

    private func connect(_ handle: HANDLE) throws {
      var overlapped = OVERLAPPED()
      guard let event = CreateEventW(nil, true, false, nil) else {
        throw WindowsPipeError.win32(operation: "CreateEventW", code: GetLastError())
      }
      defer { _ = CloseHandle(event) }
      overlapped.hEvent = event
      let connected = ConnectNamedPipe(handle, &overlapped)
      if !connected {
        let code = GetLastError()
        guard code == ERROR_IO_PENDING || code == ERROR_PIPE_CONNECTED else {
          if code == ERROR_OPERATION_ABORTED { throw WindowsPipeError.connectionClosed }
          throw WindowsPipeError.win32(operation: "ConnectNamedPipe", code: code)
        }
        if code == ERROR_IO_PENDING {
          if !isOpen() {
            _ = CancelIoEx(handle, nil)
          }
          let result = WaitForSingleObject(event, INFINITE)
          guard result == WAIT_OBJECT_0 else {
            throw WindowsPipeError.win32(operation: "WaitForSingleObject", code: GetLastError())
          }
          var transferred: DWORD = 0
          guard GetOverlappedResult(handle, &overlapped, &transferred, false) else {
            let resultCode = GetLastError()
            if resultCode == ERROR_OPERATION_ABORTED {
              throw WindowsPipeError.connectionClosed
            }
            throw WindowsPipeError.win32(
              operation: "GetOverlappedResult", code: resultCode)
          }
        }
      }
    }

    private func verifyClient(_ handle: HANDLE) throws {
      var processID: ULONG = 0
      guard GetNamedPipeClientProcessId(handle, &processID) else {
        throw WindowsPipeError.win32(
          operation: "GetNamedPipeClientProcessId", code: GetLastError())
      }
      guard let process = OpenProcess(DWORD(PROCESS_QUERY_LIMITED_INFORMATION), false, processID)
      else {
        throw WindowsPipeError.win32(operation: "OpenProcess", code: GetLastError())
      }
      defer { _ = CloseHandle(process) }
      var token: HANDLE?
      guard
        OpenProcessToken(
          process,
          DWORD(TOKEN_QUERY),
          &token),
        let token
      else {
        throw WindowsPipeError.win32(operation: "OpenProcessToken", code: GetLastError())
      }
      defer { _ = CloseHandle(token) }

      var required: DWORD = 0
      _ = GetTokenInformation(token, TokenUser, nil, 0, &required)
      guard required > 0 else {
        throw WindowsPipeError.win32(operation: "GetTokenInformation", code: GetLastError())
      }
      let memory = UnsafeMutableRawPointer.allocate(
        byteCount: Int(required), alignment: MemoryLayout<UInt64>.alignment)
      defer { memory.deallocate() }
      guard GetTokenInformation(token, TokenUser, memory, required, &required) else {
        throw WindowsPipeError.win32(operation: "GetTokenInformation", code: GetLastError())
      }
      let tokenUser = memory.assumingMemoryBound(to: TOKEN_USER.self).pointee
      var clientSID: LPWSTR?
      guard ConvertSidToStringSidW(tokenUser.User.Sid, &clientSID), let clientSID else {
        throw WindowsPipeError.win32(operation: "ConvertSidToStringSidW", code: GetLastError())
      }
      defer { _ = LocalFree(HLOCAL(clientSID)) }
      let actual = String(decodingCString: clientSID, as: UTF16.self)
      guard actual.caseInsensitiveCompare(sid) == .orderedSame else {
        throw WindowsPipeError.serverIdentityRejected
      }
    }
  }

  /// Client-side dial with bounded availability waiting and server-token
  /// verification. The server PID is resolved through the pipe itself, then
  /// checked against the current user's token before any protocol bytes flow.
  public enum WindowsNamedPipeClient {
    public static func connect(
      to name: String,
      timeoutMilliseconds: DWORD = 2_000
    ) throws -> WindowsNamedPipeConnection {
      try withWideString(name) { wideName in
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutMilliseconds) / 1_000)
        let handle: HANDLE
        while true {
          let remainingMilliseconds = max(
            0, Int(deadline.timeIntervalSinceNow * 1_000))
          guard remainingMilliseconds > 0 else {
            throw WindowsPipeError.win32(
              operation: "WaitNamedPipeW", code: UInt32(bitPattern: ERROR_SEM_TIMEOUT))
          }
          if !WaitNamedPipeW(wideName, DWORD(min(remainingMilliseconds, 100))) {
            let code = GetLastError()
            guard code == ERROR_FILE_NOT_FOUND || code == ERROR_PIPE_BUSY,
              Date() < deadline
            else {
              throw WindowsPipeError.win32(operation: "WaitNamedPipeW", code: code)
            }
            Thread.sleep(forTimeInterval: 0.01)
            continue
          }

          if let candidate = CreateFileW(
            wideName,
            DWORD(GENERIC_READ) | DWORD(bitPattern: GENERIC_WRITE),
            0,
            nil,
            DWORD(OPEN_EXISTING),
            DWORD(FILE_FLAG_OVERLAPPED),
            nil),
            candidate != INVALID_HANDLE_VALUE
          {
            handle = candidate
            break
          }

          let code = GetLastError()
          guard code == ERROR_FILE_NOT_FOUND || code == ERROR_PIPE_BUSY,
            Date() < deadline
          else {
            throw WindowsPipeError.win32(operation: "CreateFileW", code: code)
          }
          Thread.sleep(forTimeInterval: 0.01)
        }
        do {
          var mode = DWORD(PIPE_READMODE_BYTE)
          guard SetNamedPipeHandleState(handle, &mode, nil, nil) else {
            throw WindowsPipeError.win32(
              operation: "SetNamedPipeHandleState", code: GetLastError())
          }
          try verifyServer(handle)
          return WindowsNamedPipeConnection(handle: handle, pipeName: name)
        } catch {
          _ = CloseHandle(handle)
          throw error
        }
      }
    }

    private static func verifyServer(_ handle: HANDLE) throws {
      var processID: ULONG = 0
      guard GetNamedPipeServerProcessId(handle, &processID) else {
        throw WindowsPipeError.win32(
          operation: "GetNamedPipeServerProcessId", code: GetLastError())
      }
      guard let process = OpenProcess(DWORD(PROCESS_QUERY_LIMITED_INFORMATION), false, processID)
      else {
        throw WindowsPipeError.win32(operation: "OpenProcess", code: GetLastError())
      }
      defer { _ = CloseHandle(process) }
      var token: HANDLE?
      guard OpenProcessToken(process, DWORD(TOKEN_QUERY), &token), let token else {
        throw WindowsPipeError.win32(operation: "OpenProcessToken", code: GetLastError())
      }
      defer { _ = CloseHandle(token) }
      var required: DWORD = 0
      _ = GetTokenInformation(token, TokenUser, nil, 0, &required)
      guard required > 0 else {
        throw WindowsPipeError.win32(operation: "GetTokenInformation", code: GetLastError())
      }
      let memory = UnsafeMutableRawPointer.allocate(
        byteCount: Int(required), alignment: MemoryLayout<UInt64>.alignment)
      defer { memory.deallocate() }
      guard GetTokenInformation(token, TokenUser, memory, required, &required) else {
        throw WindowsPipeError.win32(operation: "GetTokenInformation", code: GetLastError())
      }
      let tokenUser = memory.assumingMemoryBound(to: TOKEN_USER.self).pointee
      var serverSID: LPWSTR?
      guard ConvertSidToStringSidW(tokenUser.User.Sid, &serverSID), let serverSID else {
        throw WindowsPipeError.win32(operation: "ConvertSidToStringSidW", code: GetLastError())
      }
      defer { _ = LocalFree(HLOCAL(serverSID)) }
      let expected = try WindowsUserIdentity.currentSID()
      let actual = String(decodingCString: serverSID, as: UTF16.self)
      guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
        throw WindowsPipeError.serverIdentityRejected
      }
    }
  }
#endif
