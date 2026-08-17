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
    case writeOutcomeUnknown
    case invalidFrame
    case invalidPipeName
    case serverIdentityRejected
    case instanceAlreadyRunning
    case rendezvousSecretInUse

    static func isPeerDisconnectCode(_ code: UInt32) -> Bool {
      [
        UInt32(truncatingIfNeeded: ERROR_BROKEN_PIPE),
        UInt32(truncatingIfNeeded: ERROR_NO_DATA),
        UInt32(truncatingIfNeeded: ERROR_PIPE_NOT_CONNECTED),
        UInt32(truncatingIfNeeded: ERROR_OPERATION_ABORTED),
        UInt32(truncatingIfNeeded: ERROR_CONNECTION_ABORTED),
        UInt32(truncatingIfNeeded: ERROR_NETNAME_DELETED),
      ].contains(code)
    }

    static func classifyWriteCancellation(
      cancelSucceeded: Bool,
      cancelError: UInt32?,
      completionSucceeded: Bool,
      completionCode: UInt32,
      transferred: UInt32
    ) -> Self {
      if completionSucceeded || transferred > 0 {
        return .writeOutcomeUnknown
      }
      if cancelSucceeded, completionCode == UInt32(truncatingIfNeeded: ERROR_OPERATION_ABORTED) {
        return .timedOut
      }
      _ = cancelError
      return .writeOutcomeUnknown
    }
  }

  private final class WindowsPipeHandle: @unchecked Sendable {
    let value: HANDLE

    init(_ value: HANDLE) {
      self.value = value
    }
  }

  enum WindowsPipeSecurity {
    static func descriptor(for sid: String) -> String {
      "D:P(A;;GA;;;\(sid))"
    }

    static func attributes(for sid: String) throws -> (SECURITY_ATTRIBUTES, HLOCAL) {
      try attributes(descriptorText: descriptor(for: sid))
    }

    static func fileAttributes(for sid: String) throws -> (SECURITY_ATTRIBUTES, HLOCAL) {
      try attributes(descriptorText: fileDescriptor(for: sid))
    }

    private static func attributes(
      descriptorText: String
    ) throws -> (SECURITY_ATTRIBUTES, HLOCAL) {
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

    static func validate(path: String, sid: String) throws {
      var descriptor: PSECURITY_DESCRIPTOR?
      let result = withWideString(path) { widePath in
        GetNamedSecurityInfoW(
          widePath,
          SE_FILE_OBJECT,
          SECURITY_INFORMATION(
            OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION),
          nil,
          nil,
          nil,
          nil,
          &descriptor)
      }
      guard result == ERROR_SUCCESS, let descriptor else {
        throw WindowsPipeError.win32(
          operation: "GetNamedSecurityInfoW", code: result)
      }
      defer { _ = LocalFree(HLOCAL(descriptor)) }

      var text: LPWSTR?
      guard
        ConvertSecurityDescriptorToStringSecurityDescriptorW(
          descriptor,
          DWORD(SDDL_REVISION_1),
          SECURITY_INFORMATION(
            OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION),
          &text,
          nil),
        let text
      else {
        throw WindowsPipeError.win32(
          operation: "ConvertSecurityDescriptorToStringSecurityDescriptorW",
          code: GetLastError())
      }
      defer { _ = LocalFree(HLOCAL(text)) }

      let sddl = String(decodingCString: text, as: UTF16.self)
      guard
        ["O:\(sid)", "O:BA", "O:SY"].contains(where: { sddl.hasPrefix($0) }),
        let daclStart = sddl.range(of: "D:"),
        String(sddl[daclStart.lowerBound...]) == WindowsPipeSecurity.fileDescriptor(for: sid)
      else {
        throw WindowsPipeError.win32(
          operation: "validate rendezvous security",
          code: UInt32(truncatingIfNeeded: ERROR_ACCESS_DENIED))
      }
    }

    private static func fileDescriptor(for sid: String) -> String {
      "D:P(A;;FA;;;\(sid))"
    }
  }

  private enum WindowsRendezvousSecret {
    static let fileName = ".graphcode-rendezvous.secret"
    static let activeGenerationFileName = ".graphcode-active-generation"
    static let byteCount = 32

    static func loadOrCreate(
      directory: URL,
      sid: String,
      stableLockName: String? = nil
    ) throws -> Data {
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true)
      let file = directory.appendingPathComponent(fileName)
      if FileManager.default.fileExists(atPath: file.path) {
        if let existing = try? validatedSecretWithRetry(at: file, sid: sid) {
          if let stableLockName, isMutexHeld(named: stableLockName) {
            guard activeGeneration(in: directory) == GraphcodeSHA256.hex(existing) else {
              throw WindowsPipeError.rendezvousSecretInUse
            }
          }
          return existing
        }
        if let stableLockName, isMutexHeld(named: stableLockName) {
          throw WindowsPipeError.rendezvousSecretInUse
        }
        try rotateInvalidSecret(at: file)
      } else if let stableLockName, isMutexHeld(named: stableLockName) {
        throw WindowsPipeError.rendezvousSecretInUse
      }
      do {
        return try createSecret(at: file, sid: sid)
      } catch WindowsPipeError.win32(_, let code)
        where code == UInt32(truncatingIfNeeded: ERROR_FILE_EXISTS)
        || code == UInt32(truncatingIfNeeded: ERROR_ALREADY_EXISTS)
      {
        do {
          return try validatedSecret(at: file, sid: sid)
        } catch {
          if let stableLockName, isMutexHeld(named: stableLockName) {
            throw WindowsPipeError.rendezvousSecretInUse
          }
          throw error
        }
      }
    }

    private static func isMutexHeld(named name: String) -> Bool {
      let handle = withWideString(name) {
        OpenMutexW(DWORD(SYNCHRONIZE), false, $0)
      }
      guard let handle else {
        return GetLastError() != ERROR_FILE_NOT_FOUND
      }
      _ = CloseHandle(handle)
      return true
    }

    static func activeGeneration(in directory: URL) -> String? {
      try? String(
        contentsOf: directory.appendingPathComponent(activeGenerationFileName),
        encoding: .utf8
      ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func recordActiveGeneration(directory: URL, generation: String) throws {
      try Data(generation.utf8).write(
        to: directory.appendingPathComponent(activeGenerationFileName),
        options: .atomic)
    }

    static func validatedSecret(at file: URL, sid: String) throws -> Data {
      try WindowsPipeSecurity.validate(path: file.path, sid: sid)
      let secret = try Data(contentsOf: file)
      guard secret.count == byteCount, secret.contains(where: { $0 != 0 }) else {
        throw WindowsPipeError.win32(
          operation: "validate rendezvous secret",
          code: UInt32(truncatingIfNeeded: ERROR_INVALID_DATA))
      }
      return secret
    }

    private static func validatedSecretWithRetry(at file: URL, sid: String) throws -> Data {
      var lastError: Error?
      for attempt in 0..<20 {
        do {
          return try validatedSecret(at: file, sid: sid)
        } catch WindowsPipeError.win32(_, let code)
          where code == UInt32(truncatingIfNeeded: ERROR_INVALID_DATA)
          || code == UInt32(truncatingIfNeeded: ERROR_SHARING_VIOLATION)
          || code == UInt32(truncatingIfNeeded: ERROR_LOCK_VIOLATION)
        {
          lastError = WindowsPipeError.win32(
            operation: "validate rendezvous secret",
            code: code)
        } catch {
          throw error
        }
        if attempt < 19 {
          Thread.sleep(forTimeInterval: 0.005)
        }
      }
      throw lastError
        ?? WindowsPipeError.win32(
          operation: "validate rendezvous secret",
          code: UInt32(truncatingIfNeeded: ERROR_INVALID_DATA))
    }

    private static func rotateInvalidSecret(at file: URL) throws {
      let quarantine = file.deletingLastPathComponent().appendingPathComponent(
        "\(file.lastPathComponent).invalid-\(UUID().uuidString)", isDirectory: false)
      try FileManager.default.moveItem(at: file, to: quarantine)
      try? FileManager.default.removeItem(at: quarantine)
    }

    private static func createSecret(at file: URL, sid: String) throws -> Data {
      var generator = SystemRandomNumberGenerator()
      let secret = Data(
        (0..<byteCount).map { _ in
          UInt8.random(in: UInt8.min...UInt8.max, using: &generator)
        })
      let temporary = file.deletingLastPathComponent().appendingPathComponent(
        "\(file.lastPathComponent).\(UUID().uuidString).tmp", isDirectory: false)
      let securityResult = try WindowsPipeSecurity.fileAttributes(for: sid)
      var security = securityResult.0
      defer { _ = LocalFree(securityResult.1) }
      defer { try? FileManager.default.removeItem(at: temporary) }

      do {
        let handle = try withWideString(temporary.path) { widePath in
          try checkPipeHandle(
            CreateFileW(
              widePath,
              DWORD(GENERIC_READ) | DWORD(bitPattern: GENERIC_WRITE),
              DWORD(FILE_SHARE_READ),
              &security,
              DWORD(CREATE_NEW),
              DWORD(FILE_ATTRIBUTE_HIDDEN | FILE_ATTRIBUTE_TEMPORARY),
              nil),
            operation: "CreateFileW rendezvous secret temporary")
        }
        defer { _ = CloseHandle(handle) }

        var written: DWORD = 0
        let success = secret.withUnsafeBytes { bytes in
          WriteFile(handle, bytes.baseAddress, DWORD(secret.count), &written, nil)
        }
        guard success, written == DWORD(secret.count), FlushFileBuffers(handle) else {
          withWideString(temporary.path) { widePath in
            _ = DeleteFileW(widePath)
          }
          throw WindowsPipeError.win32(
            operation: "write rendezvous secret", code: GetLastError())
        }
        try WindowsPipeSecurity.validate(path: temporary.path, sid: sid)
      }
      let published = withWideString(temporary.path) { source in
        withWideString(file.path) { destination in
          MoveFileExW(
            source,
            destination,
            DWORD(MOVEFILE_WRITE_THROUGH))
        }
      }
      guard published else {
        throw WindowsPipeError.win32(
          operation: "MoveFileExW rendezvous secret",
          code: GetLastError())
      }
      try WindowsPipeSecurity.validate(path: file.path, sid: sid)
      return secret
    }
  }

  private enum WindowsNamedPipeIdentity {
    static func stableValues(
      environment: [String: String],
      homeDirectory: URL
    ) throws -> (sid: String, supportHash: String) {
      let sid = try WindowsUserIdentity.currentSID()
      let configuredSupport = SupportDirectory.configuredURL(
        environment: environment, homeDirectory: homeDirectory)
      try FileManager.default.createDirectory(
        at: configuredSupport, withIntermediateDirectories: true)
      let support = SupportDirectory.url(
        environment: environment, homeDirectory: homeDirectory)
      let supportHash = GraphcodeSHA256.hex(
        Data(support.standardizedFileURL.path.lowercased().utf8))
      return (sid, supportHash)
    }

    static func values(
      environment: [String: String],
      homeDirectory: URL
    ) throws -> (sid: String, supportHash: String, rendezvousHash: String) {
      let stable = try stableValues(
        environment: environment, homeDirectory: homeDirectory)
      let configuredSupport = SupportDirectory.configuredURL(
        environment: environment, homeDirectory: homeDirectory)
      let stableLockName = WindowsDaemonInstanceLock.name(
        sid: stable.sid, supportHash: stable.supportHash)
      let secret = try WindowsRendezvousSecret.loadOrCreate(
        directory: configuredSupport,
        sid: stable.sid,
        stableLockName: stableLockName)
      return (stable.sid, stable.supportHash, GraphcodeSHA256.hex(secret))
    }

    static func taskName(
      environment: [String: String],
      homeDirectory: URL
    ) throws -> String {
      let identity = try stableValues(
        environment: environment, homeDirectory: homeDirectory)
      return taskName(
        sid: identity.sid,
        supportHash: identity.supportHash)
    }

    static func taskName(supportDirectory: URL) throws -> String {
      let sid = try WindowsUserIdentity.currentSID()
      try FileManager.default.createDirectory(
        at: supportDirectory, withIntermediateDirectories: true)
      let resolvedSupport = SupportDirectory.url(
        environment: [SupportDirectory.environmentKey: supportDirectory.path],
        homeDirectory: supportDirectory.deletingLastPathComponent())
      let supportHash = GraphcodeSHA256.hex(
        Data(resolvedSupport.standardizedFileURL.path.lowercased().utf8))
      return taskName(sid: sid, supportHash: supportHash)
    }

    static func taskName(
      sid: String,
      supportHash: String
    ) -> String {
      let material = Data("\(sid)|\(supportHash)".utf8)
      let identityHash = GraphcodeSHA256.hex(material)
      return "GraphCode\\graphcoded-\(identityHash.prefix(32))"
    }

    static func taskName(
      sid: String,
      supportHash: String,
      rendezvousHash: String
    ) -> String {
      taskName(sid: sid, supportHash: supportHash)
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
      if let override = try normalizedPipeName(environment: environment) {
        return override
      }

      let identity = try WindowsNamedPipeIdentity.values(
        environment: environment, homeDirectory: homeDirectory)
      return
        "\\\\.\\pipe\\graphcode-\(identity.sid)-\(identity.supportHash.prefix(24))-\(identity.rendezvousHash.prefix(24))"
    }

    public static func taskName(
      environment: [String: String] = ProcessInfo.processInfo.environment,
      homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> String {
      try WindowsNamedPipeIdentity.taskName(
        environment: environment, homeDirectory: homeDirectory)
    }

    public static func generation(
      environment: [String: String] = ProcessInfo.processInfo.environment,
      homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> String {
      if let override = try normalizedPipeName(environment: environment) {
        return GraphcodeSHA256.hex(Data(override.utf8))
      }
      return try WindowsNamedPipeIdentity.values(
        environment: environment, homeDirectory: homeDirectory
      ).rendezvousHash
    }

    public static func recordActiveGeneration(
      environment: [String: String] = ProcessInfo.processInfo.environment,
      homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws {
      if try normalizedPipeName(environment: environment) != nil {
        return
      }
      let support = SupportDirectory.configuredURL(
        environment: environment, homeDirectory: homeDirectory)
      let generation = try WindowsNamedPipeIdentity.values(
        environment: environment, homeDirectory: homeDirectory
      ).rendezvousHash
      try WindowsRendezvousSecret.recordActiveGeneration(
        directory: support, generation: generation)
    }

    /// Returns the canonical Windows pipe override, or `nil` when no override
    /// was supplied. The canonical form makes equivalent case/whitespace
    /// spellings share one endpoint generation.
    public static func normalizedPipeName(
      environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> String? {
      let rawValue: String?
      if let exact = environment[DaemonSocketPath.environmentKey] {
        rawValue = exact
      } else {
        rawValue = environment.keys
          .sorted()
          .first(where: {
            $0.caseInsensitiveCompare(DaemonSocketPath.environmentKey) == .orderedSame
          })
          .flatMap { environment[$0] }
      }
      guard let rawValue else {
        return nil
      }
      let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
      let prefix = "\\\\.\\pipe\\"
      guard
        value.range(of: prefix, options: [.caseInsensitive, .anchored]) != nil
      else {
        throw WindowsPipeError.invalidPipeName
      }
      let suffix = String(value.dropFirst(prefix.count))
      guard
        !suffix.isEmpty,
        value.utf16.count <= 256,
        suffix.unicodeScalars.allSatisfy({
          $0.value >= 0x20
            && $0.value != 0x5C
            && $0.value != 0x2F
            && $0.value != 0x22
        })
      else {
        throw WindowsPipeError.invalidPipeName
      }
      return prefix + suffix.lowercased()
    }

    static func taskName(sid: String, supportHash: String, rendezvousHash: String) -> String {
      WindowsNamedPipeIdentity.taskName(
        sid: sid, supportHash: supportHash, rendezvousHash: rendezvousHash)
    }

    static func taskName(supportDirectory: URL) throws -> String {
      try WindowsNamedPipeIdentity.taskName(supportDirectory: supportDirectory)
    }
  }

  /// A current-user, support-directory-scoped lifetime lock for graphcoded.
  public final class WindowsDaemonInstanceLock: @unchecked Sendable {
    private let handle: HANDLE

    public init(
      environment: [String: String] = ProcessInfo.processInfo.environment,
      homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws {
      let identity = try WindowsNamedPipeIdentity.stableValues(
        environment: environment, homeDirectory: homeDirectory)
      let name = Self.name(
        sid: identity.sid,
        supportHash: identity.supportHash)
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
      "Global\\graphcode-daemon-\(sid)-\(supportHash.prefix(20))"
    }

    public static func startupName(sid: String, supportHash: String) -> String {
      "\(name(sid: sid, supportHash: supportHash))-startup"
    }

    static func name(sid: String, supportHash: String, rendezvousHash: String) -> String {
      name(sid: sid, supportHash: supportHash)
    }

    static func securityDescriptor(for sid: String) -> String {
      WindowsPipeSecurity.descriptor(for: sid)
    }
  }

  /// Serializes every daemon launch path, including scheduled-task and shell
  /// children, before the lifetime instance lock is acquired.
  public final class WindowsDaemonStartupReservation: @unchecked Sendable {
    private let handle: HANDLE

    public init(
      environment: [String: String] = ProcessInfo.processInfo.environment,
      homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws {
      let identity = try WindowsNamedPipeIdentity.stableValues(
        environment: environment, homeDirectory: homeDirectory)
      let name = WindowsDaemonInstanceLock.startupName(
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
      if error == ERROR_ALREADY_EXISTS {
        let result = WaitForSingleObject(mutex, 5_000)
        guard result == WAIT_OBJECT_0 else {
          _ = CloseHandle(mutex)
          throw WindowsPipeError.timedOut
        }
      }
      handle = mutex
    }

    deinit {
      _ = ReleaseMutex(handle)
      _ = CloseHandle(handle)
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
    private let writeTimeout: TimeInterval
    private let lock = NSCondition()
    private var closed = false
    private var activeOperations = 0

    public init(handle: HANDLE, writeTimeout: TimeInterval = 5) {
      self.handle = handle
      self.writeTimeout = max(0.001, writeTimeout)
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
              try self.writeSynchronously(
                data, by: Date().addingTimeInterval(self.writeTimeout))
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

    fileprivate func writeFrameSynchronously(
      _ data: Data,
      timeout: TimeInterval = 5
    ) throws {
      let header = try DaemonFrameHeader.encodeLength(
        data.count,
        maxPayloadBytes: UInt32(DaemonFrameHeader.legacySafetyCeilingBytes))
      let deadline = Date().addingTimeInterval(max(0.001, timeout))
      try writeSynchronously(header, by: deadline)
      if !data.isEmpty {
        try writeSynchronously(data, by: deadline)
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

    fileprivate func hasAvailableBytes() throws -> Bool {
      try beginOperation()
      defer { endOperation() }

      var bytesRead: DWORD = 0
      var bytesAvailable: DWORD = 0
      guard PeekNamedPipe(handle, nil, 0, &bytesRead, &bytesAvailable, nil) else {
        let code = GetLastError()
        if WindowsPipeError.isPeerDisconnectCode(code) {
          throw WindowsPipeError.connectionClosed
        }
        throw WindowsPipeError.win32(operation: "PeekNamedPipe", code: code)
      }
      return bytesAvailable > 0
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
            if WindowsPipeError.isPeerDisconnectCode(code) {
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
          if WindowsPipeError.isPeerDisconnectCode(code) {
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

    private func writeSynchronously(_ data: Data, by deadline: Date? = nil) throws {
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
            if WindowsPipeError.isPeerDisconnectCode(code) {
              throw WindowsPipeError.connectionClosed
            }
            throw WindowsPipeError.win32(operation: "WriteFile", code: code)
          }
        }
        do {
          try operation.wait(timeout: try remainingTimeout(until: deadline))
        } catch WindowsPipeError.timedOut {
          var cancelSucceeded = false
          var cancelError: UInt32?
          withUnsafeMutablePointer(to: &overlapped) { pending in
            cancelSucceeded = CancelIoEx(handle, pending)
            cancelError = cancelSucceeded ? nil : GetLastError()
          }
          try? operation.wait()
          var cancelledBytes: DWORD = 0
          let completed = GetOverlappedResult(
            handle, &overlapped, &cancelledBytes, false)
          let completionCode = completed ? 0 : GetLastError()
          throw WindowsPipeError.classifyWriteCancellation(
            cancelSucceeded: cancelSucceeded,
            cancelError: cancelError,
            completionSucceeded: completed,
            completionCode: completionCode,
            transferred: cancelledBytes)
        }
        guard GetOverlappedResult(handle, &overlapped, &transferred, false) else {
          let code = GetLastError()
          if WindowsPipeError.isPeerDisconnectCode(code) {
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
    private let writeTimeout: TimeInterval
    private var closed = false

    public init(
      id: Foundation.UUID = Foundation.UUID(),
      handle: HANDLE,
      pipeName: String,
      readTimeout: TimeInterval? = nil,
      writeTimeout: TimeInterval = 5
    ) {
      self.id = id
      endpoint = .namedPipe(pipeName)
      self.writeTimeout = max(0.001, writeTimeout)
      stream = WindowsNamedPipeByteStream(handle: handle, writeTimeout: writeTimeout)
      _ = readTimeout
    }

    public func receiveFrame() async throws -> Data {
      try await FramedMessageIO.readFrame(from: stream)
    }

    public func receiveFrameWithPostHandshakeDeadline(
      _ timeout: TimeInterval = 5
    ) async throws -> Data {
      try await withTaskCancellationHandler {
        while try !stream.hasAvailableBytes() {
          try await Task.sleep(for: .milliseconds(10))
        }
        return try await withCheckedThrowingContinuation { continuation in
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

    /// Reads the initial protocol frame with a bounded wait for its first byte.
    /// Once a client starts speaking, the remaining header and payload share the
    /// post-handshake budget used by the daemon's staged reader.
    public func receiveFrameWithFirstByteDeadline(
      firstByteTimeout: TimeInterval = 5,
      postHandshakeTimeout: TimeInterval = 5
    ) async throws -> Data {
      try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          DispatchQueue.global(qos: .utility).async {
            do {
              continuation.resume(
                returning: try self.receiveFrameWithFirstByteDeadlineSynchronously(
                  firstByteTimeout: firstByteTimeout,
                  postHandshakeTimeout: postHandshakeTimeout))
            } catch {
              continuation.resume(throwing: error)
            }
          }
        }
      } onCancel: {
        self.stream.cancelPendingIO()
      }
    }

    private func receiveFrameWithFirstByteDeadlineSynchronously(
      firstByteTimeout: TimeInterval,
      postHandshakeTimeout: TimeInterval
    ) throws -> Data {
      let firstByte = try stream.readSynchronously(
        1,
        by: Date().addingTimeInterval(max(0, firstByteTimeout)))
      let deadline = Date().addingTimeInterval(max(0, postHandshakeTimeout))
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

    /// Reads one complete response under a deadline that begins before the first byte.
    /// CLI calls use this whole-response budget; daemon protocol reads use the staged
    /// method above so an idle connected client remains harmless.
    public func receiveFrameWithDeadline(_ timeout: TimeInterval) async throws -> Data {
      let deadline = Date().addingTimeInterval(max(0, timeout))
      return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          DispatchQueue.global(qos: .utility).async {
            do {
              continuation.resume(
                returning: try self.receiveFrameWithDeadlineSynchronously(deadline))
            } catch {
              continuation.resume(throwing: error)
            }
          }
        }
      } onCancel: {
        self.stream.cancelPendingIO()
      }
    }

    private func receiveFrameWithDeadlineSynchronously(_ deadline: Date) throws -> Data {
      let header = try stream.readSynchronously(
        DaemonFrameHeader.byteCount, by: deadline)
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
            try self.stream.writeFrameSynchronously(data, timeout: self.writeTimeout)
            continuation.resume()
          } catch {
            switch error {
            case WindowsPipeError.timedOut, WindowsPipeError.writeOutcomeUnknown:
              self.closeSynchronously()
            default:
              break
            }
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

  /// Limits the number of accepted connections that are still waiting for their
  /// initial protocol frame. A same-user client can connect to the pipe, but it
  /// cannot consume an unbounded daemon worker forever without sending bytes.
  public final class WindowsPipeHandshakeLimiter: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var active = 0

    public init(limit: Int = 32) {
      self.limit = max(1, limit)
    }

    public func tryAcquire() -> Permit? {
      lock.lock()
      defer { lock.unlock() }
      guard active < limit else { return nil }
      active += 1
      return Permit(owner: self)
    }

    private func release() {
      lock.lock()
      active = max(0, active - 1)
      lock.unlock()
    }

    public final class Permit: @unchecked Sendable {
      private weak var owner: WindowsPipeHandshakeLimiter?
      private let lock = NSLock()
      private var released = false

      fileprivate init(owner: WindowsPipeHandshakeLimiter) {
        self.owner = owner
      }

      public func release() {
        lock.lock()
        guard !released else {
          lock.unlock()
          return
        }
        released = true
        let owner = self.owner
        lock.unlock()
        owner?.release()
      }

      deinit { release() }
    }
  }

  /// Listener that creates one overlapped pipe instance per accept. The ACL is
  /// applied at CreateNamedPipeW time, and every accepted client is checked for
  /// the current-user SID before it is handed to the daemon.
  public final class WindowsNamedPipeListener: @unchecked Sendable, DaemonListener {
    public let endpoint: DaemonEndpoint
    private let name: String
    private let sid: String
    private let writeTimeout: TimeInterval
    private let beforeConnectionReturn: (@Sendable () -> Void)?
    private let lock = NSCondition()
    private var closed = false
    private var pendingHandles: Set<UInt> = []
    private var transferringHandles: Set<UInt> = []

    public init(
      pipeName: String? = nil,
      backlog: Int = 16,
      writeTimeout: TimeInterval = 5,
      beforeConnectionReturn: (@Sendable () -> Void)? = nil
    ) throws {
      _ = backlog
      name = try pipeName ?? WindowsNamedPipeEndpoint.name()
      sid = try WindowsUserIdentity.currentSID()
      self.writeTimeout = max(0.001, writeTimeout)
      self.beforeConnectionReturn = beforeConnectionReturn
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
                try self.beginTransfer(handle)
                self.beforeConnectionReturn?()
                let connection = WindowsNamedPipeConnection(
                  handle: handle,
                  pipeName: self.name,
                  writeTimeout: self.writeTimeout)
                try self.finishTransfer(handle)
                continuation.resume(returning: connection)
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
      transferringHandles.remove(UInt(bitPattern: handle))
      lock.unlock()
    }

    private func beginTransfer(_ handle: HANDLE) throws {
      lock.lock()
      defer { lock.unlock() }
      guard !closed else {
        throw WindowsPipeError.connectionClosed
      }
      let raw = UInt(bitPattern: handle)
      guard pendingHandles.remove(raw) != nil else {
        throw WindowsPipeError.connectionClosed
      }
      transferringHandles.insert(raw)
    }

    private func finishTransfer(_ handle: HANDLE) throws {
      lock.lock()
      defer { lock.unlock() }
      let raw = UInt(bitPattern: handle)
      guard !closed, transferringHandles.remove(raw) != nil else {
        throw WindowsPipeError.connectionClosed
      }
    }

    private func closePending() {
      lock.lock()
      if closed {
        lock.unlock()
        return
      }
      closed = true
      let handles = pendingHandles.union(transferringHandles)
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
          if WindowsPipeError.isPeerDisconnectCode(code) {
            throw WindowsPipeError.connectionClosed
          }
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
            if WindowsPipeError.isPeerDisconnectCode(resultCode) {
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
    static func isRetryableWaitCode(_ code: UInt32) -> Bool {
      [
        UInt32(truncatingIfNeeded: ERROR_FILE_NOT_FOUND),
        UInt32(truncatingIfNeeded: ERROR_PIPE_BUSY),
        UInt32(truncatingIfNeeded: ERROR_SEM_TIMEOUT),
      ].contains(code)
    }

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
            guard Self.isRetryableWaitCode(code), Date() < deadline
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
          guard Self.isRetryableWaitCode(code),
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
