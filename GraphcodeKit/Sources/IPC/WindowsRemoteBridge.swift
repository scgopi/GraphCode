import Foundation

#if os(Windows)
  import WinSDK

  /// Stable, sanitized failures from the Windows remote bridge.
  public enum WindowsRemoteBridgeError: Error, Equatable, LocalizedError, Sendable {
    case invalidConfiguration
    case alreadyRunning
    case stateUnavailable
    case stateOwnershipChanged
    case stateExpired
    case listenerUnavailable
    case sshUnavailable
    case remoteForwardUnavailable
    case invalidFrame
    case frameTooLarge
    case invalidCapability
    case expiredCapability
    case backendUnavailable

    public var errorDescription: String? {
      switch self {
      case .invalidConfiguration: return "The remote bridge configuration is invalid."
      case .alreadyRunning: return "The remote bridge is already running."
      case .stateUnavailable: return "The remote bridge state is unavailable."
      case .stateOwnershipChanged: return "The remote bridge state owner changed."
      case .stateExpired: return "The remote bridge state expired."
      case .listenerUnavailable: return "The remote bridge listener is unavailable."
      case .sshUnavailable: return "The SSH forward is unavailable."
      case .remoteForwardUnavailable: return "The SSH reverse forward could not be verified."
      case .invalidFrame: return "The remote bridge received an invalid frame."
      case .frameTooLarge: return "The remote bridge frame is too large."
      case .invalidCapability: return "The remote bridge capability is invalid."
      case .expiredCapability: return "The remote bridge capability expired."
      case .backendUnavailable: return "The local graphcoded endpoint is unavailable."
      }
    }
  }

  /// A user-only, atomically replaced state record store.
  public final class WindowsRemoteBridgeStateStore: @unchecked Sendable {
    private static let lockGuard = NSLock()
    private static nonisolated(unsafe) var locks: [String: NSLock] = [:]

    public let url: URL
    private let sid: String
    private let processLock: NSLock
    private let namedLock: HANDLE

    public init(url: URL) throws {
      self.url = url
      sid = try WindowsUserIdentity.currentSID()
      let key = url.standardizedFileURL.path.lowercased()
      Self.lockGuard.lock()
      processLock =
        Self.locks[key]
        ?? {
          let lock = NSLock()
          Self.locks[key] = lock
          return lock
        }()
      Self.lockGuard.unlock()
      namedLock = try Self.makeNamedLock(for: key, sid: sid)
    }

    deinit {
      _ = CloseHandle(namedLock)
    }

    public func transaction<Result>(
      _ body: () throws -> Result
    ) throws -> Result {
      processLock.lock()
      defer { processLock.unlock() }
      let wait = WaitForSingleObject(namedLock, INFINITE)
      guard wait == WAIT_OBJECT_0 || wait == DWORD(0x80) else {
        throw WindowsRemoteBridgeError.stateUnavailable
      }
      defer { _ = ReleaseMutex(namedLock) }
      return try body()
    }

    public func read() throws -> RemoteBridgeWireState {
      try transaction {
        try readUnlocked()
      }
    }

    public func write(_ state: RemoteBridgeWireState) throws {
      try state.validated()
      try transaction {
        try writeUnlocked(state)
      }
    }

    public func writeIfMatches(
      _ expected: RemoteBridgeWireState?, _ state: RemoteBridgeWireState
    ) throws -> Bool {
      try state.validated()
      return try transaction {
        let current = try? readUnlocked()
        guard Self.matches(current, expected) else { return false }
        try writeUnlocked(state)
        return true
      }
    }

    public func removeIfMatches(_ expected: RemoteBridgeWireState) throws -> Bool {
      try transaction {
        guard let current = try? readUnlocked(), Self.matches(current, expected) else {
          return false
        }
        try? FileManager.default.removeItem(at: url)
        return true
      }
    }

    private func readUnlocked() throws -> RemoteBridgeWireState {
      var lastError: Error?
      for attempt in 0..<20 {
        do {
          let data = try Data(contentsOf: url)
          let state = try JSONDecoder().decode(RemoteBridgeWireState.self, from: data)
          try state.validated()
          return state
        } catch {
          lastError = error
          if attempt < 19 { Thread.sleep(forTimeInterval: 0.005) }
        }
      }
      throw lastError ?? WindowsRemoteBridgeError.stateUnavailable
    }

    private func writeUnlocked(_ state: RemoteBridgeWireState) throws {
      let directory = url.deletingLastPathComponent()
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true)
      let temporary = directory.appendingPathComponent(
        ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
      let data = try JSONEncoder().encode(state)
      try writeUserOnlyFile(data, to: temporary)
      defer { try? FileManager.default.removeItem(at: temporary) }

      var source = Array(temporary.path.utf16)
      source.append(0)
      var destination = Array(url.path.utf16)
      destination.append(0)
      var replaced = false
      for attempt in 0..<20 {
        replaced = source.withUnsafeBufferPointer { source in
          destination.withUnsafeBufferPointer { destination in
            MoveFileExW(
              source.baseAddress,
              destination.baseAddress,
              DWORD(MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
          }
        }
        if replaced { break }
        let error = GetLastError()
        guard
          error == ERROR_SHARING_VIOLATION || error == ERROR_ACCESS_DENIED,
          attempt < 19
        else { break }
        Thread.sleep(forTimeInterval: 0.005)
      }
      guard replaced else { throw WindowsRemoteBridgeError.stateUnavailable }
      try WindowsPipeSecurity.validate(path: url.path, sid: sid)
    }

    private static func matches(
      _ current: RemoteBridgeWireState?, _ expected: RemoteBridgeWireState?
    ) -> Bool {
      switch (current, expected) {
      case (nil, nil): return true
      case (.some(let current), .some(let expected)):
        return current.daemonInstanceID == expected.daemonInstanceID
          && current.generation == expected.generation
          && constantTimeEqual(current.capability, expected.capability)
      default: return false
      }
    }

    private static func makeNamedLock(for key: String, sid: String) throws -> HANDLE {
      let name = "Global\\graphcode-remote-bridge-\(GraphcodeSHA256.hex(Data(key.utf8)).prefix(32))"
      let securityResult = try WindowsPipeSecurity.attributes(for: sid)
      var security = securityResult.0
      defer { _ = LocalFree(securityResult.1) }
      let handle = withWideString(name) {
        CreateMutexW(&security, false, $0)
      }
      guard let handle else {
        throw WindowsRemoteBridgeError.stateUnavailable
      }
      return handle
    }

    private func writeUserOnlyFile(_ data: Data, to url: URL) throws {
      let attributes = try WindowsPipeSecurity.fileAttributes(for: sid)
      var security = attributes.0
      defer { _ = LocalFree(attributes.1) }
      let handle = withWideString(url.path) { path in
        CreateFileW(
          path,
          DWORD(GENERIC_WRITE),
          DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE),
          &security,
          DWORD(CREATE_NEW),
          DWORD(FILE_ATTRIBUTE_HIDDEN | FILE_ATTRIBUTE_TEMPORARY),
          nil)
      }
      guard let handle, handle != INVALID_HANDLE_VALUE else {
        throw WindowsRemoteBridgeError.stateUnavailable
      }
      defer { _ = CloseHandle(handle) }
      var written: DWORD = 0
      let succeeded = data.withUnsafeBytes { bytes in
        WriteFile(handle, bytes.baseAddress, DWORD(data.count), &written, nil)
      }
      guard succeeded, written == DWORD(data.count), FlushFileBuffers(handle) else {
        throw WindowsRemoteBridgeError.stateUnavailable
      }
    }
  }

  /// A framed loopback listener. It forwards one authenticated request at a time to
  /// the existing Named Pipe client, so the daemon protocol and business logic remain
  /// in `DaemonWireProtocol`/`ProjectRegistry`.
  public final class WindowsRemoteBridgeListener: @unchecked Sendable {
    public let port: UInt16

    private let pipeName: String
    private let state: @Sendable () -> RemoteBridgeWireState?
    private let timeout: TimeInterval
    private let maxConnections: Int
    private let lock = NSLock()
    private var listener: SOCKET
    private var stopped = false
    private var clients: Set<UInt64> = []
    private let workers = DispatchGroup()

    public init(
      requestedPort: UInt16 = 0,
      pipeName: String,
      timeout: TimeInterval = 5,
      maxConnections: Int = 32,
      state: @escaping @Sendable () -> RemoteBridgeWireState?
    ) throws {
      guard timeout.isFinite, timeout > 0, maxConnections > 0 else {
        throw WindowsRemoteBridgeError.invalidConfiguration
      }
      startWinsock()
      let socket = try bind(requestedPort: requestedPort)
      listener = socket.socket
      port = socket.port
      self.pipeName = pipeName
      self.timeout = timeout
      self.maxConnections = maxConnections
      self.state = state
    }

    deinit {
      stop()
    }

    public func start() {
      lock.lock()
      guard !stopped else {
        lock.unlock()
        return
      }
      lock.unlock()
      DispatchQueue.global(qos: .utility).async { [weak self] in
        self?.acceptLoop()
      }
    }

    public func stop() {
      lock.lock()
      guard !stopped else {
        lock.unlock()
        return
      }
      stopped = true
      let socket = listener
      listener = INVALID_SOCKET
      let active = clients
      clients.removeAll()
      lock.unlock()
      if socket != INVALID_SOCKET { _ = closesocket(socket) }
      for raw in active { _ = closesocket(SOCKET(raw)) }
      _ = workers.wait(timeout: .now() + 2)
    }

    private func acceptLoop() {
      var mode: u_long = 1
      lock.lock()
      let socket = listener
      lock.unlock()
      guard socket != INVALID_SOCKET else { return }
      _ = ioctlsocket(socket, FIONBIO, &mode)
      while true {
        lock.lock()
        let shouldStop = stopped
        lock.unlock()
        if shouldStop { return }

        let client = accept(socket, nil, nil)
        if client == INVALID_SOCKET {
          let code = WSAGetLastError()
          if code == WSAEWOULDBLOCK || code == WSAEINPROGRESS {
            Thread.sleep(forTimeInterval: 0.02)
            continue
          }
          return
        }

        lock.lock()
        let reject = stopped || clients.count >= maxConnections
        if !reject { clients.insert(UInt64(client)) }
        lock.unlock()
        if reject {
          _ = closesocket(client)
          continue
        }
        workers.enter()
        DispatchQueue.global(qos: .utility).async { [weak self] in
          defer { self?.workers.leave() }
          self?.handle(client)
        }
      }
    }

    private func handle(_ client: SOCKET) {
      defer {
        lock.lock()
        clients.remove(UInt64(client))
        lock.unlock()
        _ = closesocket(client)
      }
      do {
        let frame = try readFrame(from: client, timeout: timeout)
        guard
          let object = try JSONSerialization.jsonObject(with: frame) as? [String: Any],
          let capability = object["capability"] as? String,
          let generationNumber = object["generation"] as? NSNumber,
          let request = object["request"] as? [String: Any]
        else {
          try sendError("invalid_frame", to: client)
          return
        }
        let generationType = String(cString: generationNumber.objCType)
        let integerTypes = ["i", "s", "l", "q", "I", "S", "L", "Q"]
        let generation = generationNumber.uint64Value
        guard integerTypes.contains(generationType),
          generationNumber.doubleValue > 0,
          generationNumber.doubleValue == Double(generation)
        else {
          try sendError("invalid_capability", to: client)
          return
        }
        guard let current = state() else {
          try sendError("state_unavailable", to: client)
          return
        }
        let credential = credentialError(
          current: current, capability: capability, generation: generation)
        if let credential {
          try sendError(credential, to: client)
          return
        }
        let requestData = try JSONSerialization.data(
          withJSONObject: request, options: [.sortedKeys])
        let backend = try WindowsNamedPipeClient.connect(
          to: pipeName,
          timeoutMilliseconds: DWORD(max(1, Int(timeout * 1_000))))
        defer { Task { try? await backend.close() } }
        try blocking {
          try await backend.sendFrame(requestData)
        }
        let response = try blocking {
          try await backend.receiveFrameWithDeadline(self.timeout)
        }
        try writeFrame(response, to: client, timeout: timeout)
      } catch WindowsRemoteBridgeError.frameTooLarge {
        try? sendError("frame_too_large", to: client)
      } catch WindowsRemoteBridgeError.invalidCapability {
        try? sendError("invalid_capability", to: client)
      } catch WindowsRemoteBridgeError.expiredCapability {
        try? sendError("expired_capability", to: client)
      } catch {
        try? sendError(
          error is FramedMessageIO.IOError ? "invalid_frame" : "backend_unavailable",
          to: client)
      }
    }

    private func credentialError(
      current: RemoteBridgeWireState,
      capability: String,
      generation: UInt64
    ) -> String? {
      let now = Date().timeIntervalSince1970
      guard current.expiresAt > now else { return "expired_capability" }
      if generation == current.generation,
        constantTimeEqual(capability, current.capability)
      {
        return nil
      }
      if let previous = current.previous,
        previous.generation == generation,
        previous.expiresAt > now,
        constantTimeEqual(capability, previous.capability)
      {
        return nil
      }
      return "invalid_capability"
    }

    private func sendError(_ error: String, to socket: SOCKET) throws {
      let payload = try JSONSerialization.data(
        withJSONObject: ["ok": false, "error": error],
        options: [.sortedKeys])
      try writeFrame(payload, to: socket, timeout: timeout)
    }
  }

  /// Production Windows remote bridge and per-authority SSH reverse forward owner.
  public actor WindowsRemoteBridge: RemoteBridge {
    public static let defaultTTL: TimeInterval = 30 * 60
    public static let defaultPreviousOverlap: TimeInterval = 5

    private final class Entry: @unchecked Sendable {
      let authority: String
      let store: WindowsRemoteBridgeStateStore
      let listener: WindowsRemoteBridgeListener
      var session: WindowsSSHForwardSession?
      var state: RemoteBridgeWireState

      init(
        authority: String,
        store: WindowsRemoteBridgeStateStore,
        listener: WindowsRemoteBridgeListener,
        state: RemoteBridgeWireState
      ) {
        self.authority = authority
        self.store = store
        self.listener = listener
        self.state = state
      }
    }

    private let supportDirectory: URL
    private let pipeName: String
    private let ttl: TimeInterval
    private let overlap: TimeInterval
    private let maxOverlap: TimeInterval
    private let ssh: WindowsSSHForwardDriver
    private let instanceID = Foundation.UUID()
    private var entries: [String: Entry] = [:]

    public init(
      supportDirectory: URL = SupportDirectory.url,
      pipeName: String? = nil,
      ttl: TimeInterval = WindowsRemoteBridge.defaultTTL,
      previousOverlap: TimeInterval = WindowsRemoteBridge.defaultPreviousOverlap,
      maxPreviousOverlap: TimeInterval = 5,
      ssh: WindowsSSHForwardDriver = WindowsSSHForwardDriver()
    ) throws {
      guard ttl.isFinite, ttl > 0,
        previousOverlap.isFinite, previousOverlap >= 0,
        maxPreviousOverlap.isFinite, maxPreviousOverlap >= 0
      else {
        throw WindowsRemoteBridgeError.invalidConfiguration
      }
      self.supportDirectory = supportDirectory
      self.pipeName = try pipeName ?? WindowsNamedPipeEndpoint.name()
      self.ttl = ttl
      self.overlap = previousOverlap
      self.maxOverlap = maxPreviousOverlap
      self.ssh = ssh
    }

    public func ensureForwarding(authority: String) async throws -> RemoteBridgeState {
      guard !authority.isEmpty else {
        throw WindowsRemoteBridgeError.invalidConfiguration
      }
      if let entry = entries[authority] {
        if Date().timeIntervalSince1970 < entry.state.expiresAt {
          if let session = entry.session, session.isRunning {
            if (try? verifySSH(authority: authority, port: entry.state.port, session: session))
              == true
            {
              return entry.state.remoteBridgeState()
            }
            entry.session = nil
          }
          if let session = try reconnect(entry, authority: authority) {
            entry.session = session
            return entry.state.remoteBridgeState()
          }
          throw WindowsRemoteBridgeError.sshUnavailable
        }
        entry.session?.stop()
        entry.listener.stop()
        _ = try? entry.store.removeIfMatches(entry.state)
        let replacement = try startEntry(
          authority: authority, store: entry.store, generation: entry.state.generation + 1)
        entries[authority] = replacement
        return replacement.state.remoteBridgeState()
      }

      let store = try WindowsRemoteBridgeStateStore(
        url: Self.stateURL(authority: authority, supportDirectory: supportDirectory))
      let previous = try? store.read()
      let generation = (previous?.generation ?? 0) + 1
      let entry = try startEntry(
        authority: authority, store: store, generation: generation)
      entries[authority] = entry
      return entry.state.remoteBridgeState()
    }

    public func stopForwarding(authority: String) async throws {
      guard let entry = entries.removeValue(forKey: authority) else {
        let store = try WindowsRemoteBridgeStateStore(
          url: Self.stateURL(authority: authority, supportDirectory: supportDirectory))
        if let state = try? store.read() {
          let expired = state.expiresAt <= Date().timeIntervalSince1970
          if expired || !Self.loopbackReachable(state.port) {
            _ = try? store.removeIfMatches(state)
          }
        }
        return
      }
      entry.session?.stop()
      entry.listener.stop()
      _ = try? entry.store.removeIfMatches(entry.state)
    }

    public func rotate(
      authority: String, overlapSeconds: TimeInterval? = nil
    ) throws -> RemoteBridgeState {
      guard let entry = entries[authority] else {
        throw WindowsRemoteBridgeError.stateUnavailable
      }
      return try rotateEntry(entry, overlapSeconds: overlapSeconds)
    }

    public static func stateURL(authority: String, supportDirectory: URL) -> URL {
      supportDirectory
        .appendingPathComponent("remote-bridges", isDirectory: true)
        .appendingPathComponent(
          "\(GraphcodeSHA256.hex(Data(authority.utf8))).json",
          isDirectory: false)
    }

    private func startEntry(
      authority: String,
      store: WindowsRemoteBridgeStateStore,
      generation: UInt64
    ) throws -> Entry {
      var lastError: Error?
      for _ in 0..<4 {
        do {
          let listener = try WindowsRemoteBridgeListener(
            pipeName: pipeName,
            state: { [weak store] in try? store?.read() })
          let now = Date().timeIntervalSince1970
          let state = RemoteBridgeWireState(
            daemonInstanceID: instanceID,
            generation: generation,
            port: listener.port,
            capability: Self.newCapability(),
            issuedAt: now,
            expiresAt: now + ttl)
          let entry = Entry(
            authority: authority, store: store, listener: listener, state: state)
          let prior = try? store.read()
          if let prior, prior.expiresAt > now, Self.loopbackReachable(prior.port) {
            listener.stop()
            throw WindowsRemoteBridgeError.stateOwnershipChanged
          }
          guard try store.writeIfMatches(prior, state) else {
            listener.stop()
            throw WindowsRemoteBridgeError.stateOwnershipChanged
          }
          do {
            let session = try ssh.open(authority: authority, port: listener.port)
            _ = try verifySSH(authority: authority, port: listener.port, session: session)
            entry.session = session
            listener.start()
            return entry
          } catch {
            listener.stop()
            _ = try? store.removeIfMatches(state)
            throw error
          }
        } catch {
          lastError = error
          guard
            let bridgeError = error as? WindowsRemoteBridgeError,
            bridgeError == .sshUnavailable || bridgeError == .remoteForwardUnavailable
          else { throw error }
        }
      }
      throw lastError ?? WindowsRemoteBridgeError.sshUnavailable
    }

    private func reconnect(
      _ entry: Entry, authority: String
    ) throws -> WindowsSSHForwardSession? {
      for attempt in 0..<3 {
        do {
          let session = try ssh.open(authority: authority, port: entry.state.port)
          _ = try verifySSH(authority: authority, port: entry.state.port, session: session)
          return session
        } catch {
          if attempt < 2 { Thread.sleep(forTimeInterval: Double(attempt + 1)) }
        }
      }
      return nil
    }

    private func rotateEntry(
      _ entry: Entry, overlapSeconds: TimeInterval? = nil
    ) throws -> RemoteBridgeState {
      let requested = overlapSeconds ?? overlap
      guard requested.isFinite, requested >= 0 else {
        throw WindowsRemoteBridgeError.invalidConfiguration
      }
      let bounded = min(requested, maxOverlap)
      let current = try entry.store.read()
      guard current.daemonInstanceID == entry.state.daemonInstanceID,
        current.generation == entry.state.generation,
        constantTimeEqual(current.capability, entry.state.capability)
      else {
        throw WindowsRemoteBridgeError.stateOwnershipChanged
      }
      let now = Date().timeIntervalSince1970
      guard current.expiresAt > now else { throw WindowsRemoteBridgeError.stateExpired }
      let next = RemoteBridgeWireState(
        daemonInstanceID: instanceID,
        generation: current.generation + 1,
        port: current.port,
        capability: Self.newCapability(),
        issuedAt: now,
        expiresAt: now + ttl,
        previous: bounded > 0
          ? RemoteBridgePreviousWireState(
            generation: current.generation,
            capability: current.capability,
            expiresAt: min(current.expiresAt, now + bounded))
          : nil)
      guard try entry.store.writeIfMatches(current, next) else {
        throw WindowsRemoteBridgeError.stateOwnershipChanged
      }
      entry.state = next
      return next.remoteBridgeState()
    }

    private func verifySSH(
      authority: String,
      port: UInt16,
      session: WindowsSSHForwardSession
    ) throws -> Bool {
      guard session.isRunning else { throw WindowsRemoteBridgeError.sshUnavailable }
      guard try ssh.verify(authority: authority, port: port) else {
        session.stop()
        throw WindowsRemoteBridgeError.remoteForwardUnavailable
      }
      return true
    }

    private static func newCapability() -> String {
      var generator = SystemRandomNumberGenerator()
      return (0..<32).map { _ in
        String(format: "%02x", UInt8.random(in: UInt8(0)...UInt8(255), using: &generator))
      }.joined()
    }

    private static func loopbackReachable(_ port: UInt16) -> Bool {
      startWinsock()
      let client = socket(AF_INET, Int32(SOCK_STREAM), Int32(IPPROTO_TCP.rawValue))
      guard client != INVALID_SOCKET else { return false }
      defer { _ = closesocket(client) }
      var address = sockaddr_in()
      address.sin_family = ADDRESS_FAMILY(AF_INET)
      address.sin_port = htons(port)
      address.sin_addr.S_un.S_addr = UInt32(0x0100_007F)
      let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          WinSDK.connect(client, $0, Int32(MemoryLayout<sockaddr_in>.size))
        }
      }
      return result == 0
    }
  }

  public final class WindowsSSHForwardSession: @unchecked Sendable {
    private let process: Process

    init(process: Process) {
      self.process = process
    }

    public var isRunning: Bool { process.isRunning }

    public func stop() {
      if process.isRunning { process.terminate() }
    }
  }

  /// Injectable SSH boundary for controlled local fixtures and production OpenSSH.
  public struct WindowsSSHForwardDriver: @unchecked Sendable {
    private let opener: @Sendable (String, UInt16) throws -> WindowsSSHForwardSession
    private let verifier: @Sendable (String, UInt16) throws -> Bool

    public init(
      opener: @escaping @Sendable (String, UInt16) throws -> WindowsSSHForwardSession? = {
        authority, port in
        try WindowsSSHForwardDriver.openDefault(authority: authority, port: port)
      },
      verifier: @escaping @Sendable (String, UInt16) throws -> Bool = { authority, port in
        try WindowsSSHForwardDriver.verifyDefault(authority: authority, port: port)
      }
    ) {
      self.opener = { authority, port in
        guard let session = try opener(authority, port) else {
          throw WindowsRemoteBridgeError.sshUnavailable
        }
        return session
      }
      self.verifier = verifier
    }

    func open(authority: String, port: UInt16) throws -> WindowsSSHForwardSession {
      try opener(authority, port)
    }

    func verify(authority: String, port: UInt16) throws -> Bool {
      try verifier(authority, port)
    }

    public static func openDefault(
      authority: String, port: UInt16
    ) throws -> WindowsSSHForwardSession? {
      guard let executable = sshExecutable() else { return nil }
      var arguments = commonArguments(for: authority)
      arguments += [
        "-o", "StrictHostKeyChecking=yes",
        "-o", "ExitOnForwardFailure=yes",
        "-o", "GatewayPorts=no",
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=10",
        "-o", "ServerAliveInterval=5",
        "-o", "ServerAliveCountMax=3",
        "-N",
        "-R", "127.0.0.1:\(port):127.0.0.1:\(port)",
      ]
      let process = Process()
      process.executableURL = executable
      process.arguments = arguments
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      try process.run()
      return WindowsSSHForwardSession(process: process)
    }

    public static func verifyDefault(authority: String, port: UInt16) throws -> Bool {
      guard let executable = sshExecutable() else { return false }
      let python =
        "import shutil,socket,subprocess,sys; "
        + "p=int(sys.argv[1]); "
        + "s=socket.create_connection(('127.0.0.1',p),2); s.close(); "
        + "ss=shutil.which('ss'); "
        + "out=subprocess.run([ss,'-H','-ltn'],capture_output=True,text=True) if ss else None; "
        + "(not ss or out.returncode != 0 or any(('127.0.0.1:'+str(p)) in line "
        + "or ('[::1]:'+str(p)) in line or ('::1:'+str(p)) in line "
        + "for line in out.stdout.splitlines())) or sys.exit(1)"
      var arguments = commonArguments(for: authority)
      arguments += [
        "-o", "StrictHostKeyChecking=yes",
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=5",
        "--", "python3", "-c", python, String(port),
      ]
      let request = ProcessRequest(
        executable: executable,
        arguments: arguments)
      let semaphore = DispatchSemaphore(value: 0)
      let result = LockedResult<ProcessResult>()
      Task {
        do {
          result.store(
            .success(
              try await FoundationProcessRunner().run(
                request, timeout: .seconds(5))))
        } catch {
          result.store(.failure(error))
        }
        semaphore.signal()
      }
      semaphore.wait()
      return (try? result.value().exitCode) == 0
    }

    private static func commonArguments(for authority: String) -> [String] {
      if let colon = authority.lastIndex(of: ":"),
        let port = Int(authority[authority.index(after: colon)...]),
        authority[..<colon].contains("@") || !authority[..<colon].contains(":")
      {
        return ["-p", String(port), String(authority[..<colon])]
      }
      return [authority]
    }

    private static func sshExecutable() -> URL? {
      let environment = ProcessInfo.processInfo.environment
      let candidates =
        environment["PATH"]?
        .split(separator: ";")
        .map(String.init)
        .map { URL(fileURLWithPath: $0).appendingPathComponent("ssh.exe") }
        ?? []
      let systemRoot = environment["SystemRoot"] ?? environment["WINDIR"] ?? "C:\\Windows"
      let system = URL(fileURLWithPath: systemRoot)
        .appendingPathComponent("System32/OpenSSH/ssh.exe")
      return (candidates + [system]).first {
        FileManager.default.isExecutableFile(atPath: $0.path)
      }
    }
  }

  private final class LockedResult<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?

    func store(_ result: Result<Value, Error>) {
      lock.lock()
      self.result = result
      lock.unlock()
    }

    func value() throws -> Value {
      lock.lock()
      defer { lock.unlock() }
      guard let result else { throw WindowsRemoteBridgeError.sshUnavailable }
      return try result.get()
    }
  }

  private func readFrame(
    from socket: SOCKET, timeout: TimeInterval
  ) throws -> Data {
    let deadline = Date().addingTimeInterval(timeout)
    let header = try readExactly(4, from: socket, deadline: deadline)
    let bytes = [UInt8](header)
    let length = Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
    guard length >= 0, length <= Int(DaemonFrameHeader.legacySafetyCeilingBytes) else {
      throw WindowsRemoteBridgeError.frameTooLarge
    }
    return length == 0 ? Data() : try readExactly(length, from: socket, deadline: deadline)
  }

  private func writeFrame(
    _ data: Data, to socket: SOCKET, timeout: TimeInterval
  ) throws {
    guard data.count <= Int(DaemonFrameHeader.legacySafetyCeilingBytes) else {
      throw WindowsRemoteBridgeError.frameTooLarge
    }
    let length = UInt32(data.count)
    var frame = Data([
      UInt8((length >> 24) & 0xff),
      UInt8((length >> 16) & 0xff),
      UInt8((length >> 8) & 0xff),
      UInt8(length & 0xff),
    ])
    frame.append(data)
    try writeAll(frame, to: socket, deadline: Date().addingTimeInterval(timeout))
  }

  private func readExactly(
    _ count: Int, from socket: SOCKET, deadline: Date
  ) throws -> Data {
    var result = Data()
    result.reserveCapacity(count)
    while result.count < count {
      try setSocketTimeout(socket, until: deadline)
      let requested = count - result.count
      var buffer = [UInt8](repeating: 0, count: requested)
      let received = buffer.withUnsafeMutableBytes {
        recv(socket, $0.baseAddress, Int32(requested), 0)
      }
      guard received > 0 else {
        if WSAGetLastError() == WSAETIMEDOUT { throw WindowsRemoteBridgeError.invalidFrame }
        throw WindowsRemoteBridgeError.invalidFrame
      }
      result.append(contentsOf: buffer.prefix(Int(received)))
    }
    return result
  }

  private func writeAll(
    _ data: Data, to socket: SOCKET, deadline: Date
  ) throws {
    var offset = 0
    while offset < data.count {
      try setSocketTimeout(socket, until: deadline, sending: true)
      let sent = data.withUnsafeBytes {
        send(socket, $0.baseAddress!.advanced(by: offset), Int32(data.count - offset), 0)
      }
      guard sent > 0 else { throw WindowsRemoteBridgeError.backendUnavailable }
      offset += Int(sent)
    }
  }

  private func setSocketTimeout(
    _ socket: SOCKET, until deadline: Date, sending: Bool = false
  ) throws {
    let remaining = deadline.timeIntervalSinceNow
    guard remaining > 0 else { throw WindowsRemoteBridgeError.invalidFrame }
    var milliseconds = DWORD(min(Double(DWORD.max), max(1, (remaining * 1_000).rounded(.up))))
    let option = sending ? SO_SNDTIMEO : SO_RCVTIMEO
    let result = withUnsafePointer(to: &milliseconds) {
      setsockopt(socket, SOL_SOCKET, option, $0, Int32(MemoryLayout<DWORD>.size))
    }
    guard result == 0 else { throw WindowsRemoteBridgeError.invalidFrame }
  }

  private func blocking<Result>(
    _ operation: @escaping @Sendable () async throws -> Result
  ) throws -> Result {
    let semaphore = DispatchSemaphore(value: 0)
    let result = LockedResult<Result>()
    Task {
      do {
        result.store(.success(try await operation()))
      } catch {
        result.store(.failure(error))
      }
      semaphore.signal()
    }
    semaphore.wait()
    return try result.value()
  }

  private func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
    guard RemoteBridgeWireState.isCapability(lhs), RemoteBridgeWireState.isCapability(rhs)
    else { return false }
    var difference: UInt8 = 0
    for (left, right) in zip(lhs.utf8, rhs.utf8) {
      difference |= left ^ right
    }
    return difference == 0
  }

  private func withWideString<Result>(
    _ value: String, _ body: (UnsafePointer<WCHAR>) throws -> Result
  ) rethrows -> Result {
    var buffer = Array(value.utf16)
    buffer.append(0)
    return try buffer.withUnsafeBufferPointer { try body($0.baseAddress!) }
  }

  private func startWinsock() {
    struct State {
      static let lock = NSLock()
      static nonisolated(unsafe) var started = false
    }
    State.lock.lock()
    defer { State.lock.unlock() }
    guard !State.started else { return }
    var data = WSADATA()
    guard WSAStartup(WORD(0x202), &data) == 0 else { return }
    State.started = true
  }

  private func bind(requestedPort: UInt16) throws -> (socket: SOCKET, port: UInt16) {
    let socket = socket(AF_INET, Int32(SOCK_STREAM), Int32(IPPROTO_TCP.rawValue))
    guard socket != INVALID_SOCKET else {
      throw WindowsRemoteBridgeError.listenerUnavailable
    }
    var address = sockaddr_in()
    address.sin_family = ADDRESS_FAMILY(AF_INET)
    address.sin_port = htons(requestedPort)
    address.sin_addr.S_un.S_addr = UInt32(0x0100_007F)
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        WinSDK.bind(socket, $0, Int32(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bound == 0, listen(socket, 32) == 0 else {
      _ = closesocket(socket)
      throw WindowsRemoteBridgeError.listenerUnavailable
    }
    var length = Int32(MemoryLayout<sockaddr_in>.size)
    var actual = sockaddr_in()
    let named = withUnsafeMutablePointer(to: &actual) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getsockname(socket, $0, &length)
      }
    }
    guard named == 0 else {
      _ = closesocket(socket)
      throw WindowsRemoteBridgeError.listenerUnavailable
    }
    return (socket, ntohs(actual.sin_port))
  }
#endif
