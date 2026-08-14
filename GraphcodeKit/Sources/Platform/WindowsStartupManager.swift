import Foundation

#if os(Windows)
  import WinSDK

  /// Per-user Task Scheduler integration for the Windows daemon. It avoids
  /// elevation and keeps startup state in the user's profile, matching the
  /// current-user named-pipe ACL.
  public struct WindowsStartupManager: StartupManager {
    public let daemonURL: URL
    public let supportDirectory: URL
    public let taskName: String
    public let launcherURL: URL
    private let pipeOverride: String?
    private let runner: any ProcessRunner

    public init(
      daemonURL: URL = SupportDirectory.binDirectory.appendingPathComponent("graphcoded.exe"),
      taskName: String? = nil,
      supportDirectory: URL? = nil,
      environment: [String: String] = ProcessInfo.processInfo.environment,
      runner: any ProcessRunner = FoundationProcessRunner()
    ) throws {
      self.daemonURL = daemonURL
      let resolvedSupportDirectory =
        supportDirectory
        ?? SupportDirectory.configuredURL(
          environment: environment,
          homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
      self.supportDirectory = resolvedSupportDirectory
      self.pipeOverride = try WindowsNamedPipeEndpoint.normalizedPipeName(
        environment: environment)
      self.taskName =
        try taskName
        ?? WindowsNamedPipeEndpoint.taskName(
          supportDirectory: resolvedSupportDirectory)
      self.launcherURL = daemonURL.deletingLastPathComponent()
        .appendingPathComponent("graphcoded-launcher.ps1")
      self.runner = runner
    }

    public func installAndStart() async throws {
      try writeLauncher()
      let create = try await run(
        arguments: [
          "/Create", "/TN", taskName, "/SC", "ONLOGON", "/TR",
          taskAction, "/F", "/RL", "LIMITED",
        ])
      guard create.exitCode == 0 else {
        throw StartupManagerError.commandFailed(
          command: "schtasks /Create", output: output(create))
      }

      let start = try await run(arguments: ["/Run", "/TN", taskName])
      guard start.exitCode == 0 else {
        throw StartupManagerError.commandFailed(
          command: "schtasks /Run", output: output(start))
      }
    }

    public func stop() async throws {
      guard try await status() == .running else { return }
      let stop = try await run(arguments: ["/End", "/TN", taskName])
      guard stop.exitCode == 0 else {
        throw StartupManagerError.commandFailed(
          command: "schtasks /End", output: output(stop))
      }
    }

    public func waitForDaemonExit(timeout: TimeInterval = 10) async throws {
      let probe: @Sendable () -> Bool = { [self] in isDaemonProcessRunning() }
      try await Self.waitForExit(timeout: timeout, isRunning: probe)
    }

    static func waitForExit(
      timeout: TimeInterval,
      isRunning: @escaping @Sendable () -> Bool
    ) async throws {
      let deadline = Date().addingTimeInterval(max(0, timeout))
      while Date() < deadline {
        if !isRunning() { return }
        try await Task.sleep(for: .milliseconds(50))
      }
      throw StartupManagerError.commandFailed(
        command: "graphcoded termination", output: "the daemon process is still running")
    }

    public func uninstall() async throws {
      let query = try await run(arguments: ["/Query", "/TN", taskName])
      guard query.exitCode == 0 else { return }
      let delete = try await run(arguments: ["/Delete", "/TN", taskName, "/F"])
      guard delete.exitCode == 0 else {
        throw StartupManagerError.commandFailed(
          command: "schtasks /Delete", output: output(delete))
      }
    }

    public func stopAndUninstall() async throws {
      try await stop()
      try await waitForDaemonExit()
      try await uninstall()
    }

    public func status() async throws -> StartupStatus {
      let query = try await run(arguments: ["/Query", "/TN", taskName])
      return Self.status(
        taskQuerySucceeded: query.exitCode == 0,
        daemonProcessRunning: isDaemonProcessRunning())
    }

    static func status(taskQuerySucceeded: Bool, daemonProcessRunning: Bool) -> StartupStatus {
      guard taskQuerySucceeded else { return .notInstalled }
      return daemonProcessRunning ? .running : .stopped
    }

    public func isDaemonProcessRunning() -> Bool {
      let targetName = daemonURL.lastPathComponent.lowercased()
      guard let currentSID = try? WindowsUserIdentity.currentSID(),
        let snapshot = CreateToolhelp32Snapshot(DWORD(TH32CS_SNAPPROCESS), 0),
        snapshot != INVALID_HANDLE_VALUE
      else {
        return false
      }
      defer { _ = CloseHandle(snapshot) }

      var entry = PROCESSENTRY32W()
      entry.dwSize = DWORD(MemoryLayout<PROCESSENTRY32W>.size)
      guard Process32FirstW(snapshot, &entry) else { return false }
      repeat {
        let name = withUnsafeBytes(of: &entry.szExeFile) { bytes in
          let units = bytes.bindMemory(to: UInt16.self)
          let end = units.firstIndex(of: 0) ?? units.count
          return String(decoding: units[..<end], as: UTF16.self).lowercased()
        }
        if name == targetName,
          Self.processImageMatches(
            entry.th32ProcessID, expectedPath: daemonURL.standardizedFileURL.path),
          Self.processBelongsToCurrentUser(entry.th32ProcessID, sid: currentSID)
        {
          return true
        }
      } while Process32NextW(snapshot, &entry)
      return false
    }

    private static func processImageMatches(_ processID: DWORD, expectedPath: String) -> Bool {
      guard
        let process = OpenProcess(
          DWORD(PROCESS_QUERY_LIMITED_INFORMATION), false, processID)
      else {
        return false
      }
      defer { _ = CloseHandle(process) }

      var buffer = [WCHAR](repeating: 0, count: 32_768)
      var length = DWORD(buffer.count)
      guard
        buffer.withUnsafeMutableBufferPointer({
          QueryFullProcessImageNameW(process, 0, $0.baseAddress, &length)
        })
      else {
        return false
      }
      let actualPath = String(decoding: buffer.prefix(Int(length)), as: UTF16.self)
      return actualPath.caseInsensitiveCompare(expectedPath) == .orderedSame
    }

    private static func processBelongsToCurrentUser(_ processID: DWORD, sid: String) -> Bool {
      guard
        let process = OpenProcess(
          DWORD(PROCESS_QUERY_LIMITED_INFORMATION), false, processID)
      else {
        return false
      }
      defer { _ = CloseHandle(process) }
      var token: HANDLE?
      guard OpenProcessToken(process, DWORD(TOKEN_QUERY), &token), let token else {
        return false
      }
      defer { _ = CloseHandle(token) }
      var required: DWORD = 0
      _ = GetTokenInformation(token, TokenUser, nil, 0, &required)
      guard required > 0 else { return false }
      let memory = UnsafeMutableRawPointer.allocate(
        byteCount: Int(required), alignment: MemoryLayout<UInt64>.alignment)
      defer { memory.deallocate() }
      guard GetTokenInformation(token, TokenUser, memory, required, &required) else {
        return false
      }
      let tokenUser = memory.assumingMemoryBound(to: TOKEN_USER.self).pointee
      var stringSID: LPWSTR?
      guard ConvertSidToStringSidW(tokenUser.User.Sid, &stringSID), let stringSID else {
        return false
      }
      defer { _ = LocalFree(HLOCAL(stringSID)) }
      return String(decodingCString: stringSID, as: UTF16.self)
        .caseInsensitiveCompare(sid) == .orderedSame
    }

    private func run(arguments: [String]) async throws -> ProcessResult {
      let executable =
        systemRootURL
        .appendingPathComponent("System32", isDirectory: true)
        .appendingPathComponent("schtasks.exe")
      return try await runner.run(
        ProcessRequest(executable: executable, arguments: arguments),
        timeout: .seconds(30))
    }

    private var systemRootURL: URL {
      let systemRoot =
        ProcessInfo.processInfo.environment["SystemRoot"]
        ?? ProcessInfo.processInfo.environment["WINDIR"]
        ?? "C:\\Windows"
      return URL(fileURLWithPath: systemRoot)
    }

    private var taskAction: String {
      let powerShell =
        systemRootURL
        .appendingPathComponent("System32", isDirectory: true)
        .appendingPathComponent("WindowsPowerShell", isDirectory: true)
        .appendingPathComponent("v1.0", isDirectory: true)
        .appendingPathComponent("powershell.exe")
        .path
        .replacingOccurrences(of: "/", with: "\\")
      let command = Self.encodedPowerShellCommand(
        Self.launcherContents(
          daemonURL: daemonURL,
          supportDirectory: supportDirectory,
          pipeOverride: pipeOverride))
      return "\"\(powerShell)\" -NoLogo -NoProfile -NonInteractive "
        + "-ExecutionPolicy Bypass -EncodedCommand \(command)"
    }

    private func writeLauncher() throws {
      try FileManager.default.createDirectory(
        at: launcherURL.deletingLastPathComponent(),
        withIntermediateDirectories: true)
      let legacyLauncher = launcherURL.deletingLastPathComponent()
        .appendingPathComponent("graphcoded-launcher.cmd")
      try? FileManager.default.removeItem(at: legacyLauncher)
      try Self.launcherContents(
        daemonURL: daemonURL,
        supportDirectory: supportDirectory,
        pipeOverride: pipeOverride
      ).write(to: launcherURL, atomically: true, encoding: .utf16)
    }

    func launcherIsCurrent() -> Bool {
      guard
        let contents = try? String(contentsOf: launcherURL, encoding: .utf16)
      else {
        return false
      }
      return contents
        == Self.launcherContents(
          daemonURL: daemonURL,
          supportDirectory: supportDirectory,
          pipeOverride: pipeOverride)
    }

    static func launcherContents(
      daemonURL: URL,
      supportDirectory: URL,
      pipeOverride: String? = nil
    ) -> String {
      var lines = [
        "$env:GRAPHCODE_SUPPORT_DIR = \(powerShellLiteral(supportDirectory.path))"
      ]
      if let pipeOverride {
        lines.append(
          "$env:GRAPHCODE_SOCKET = \(powerShellLiteral(pipeOverride))")
      }
      lines.append(contentsOf: [
        "& \(powerShellLiteral(daemonURL.path)) @args",
        "exit $LASTEXITCODE",
      ])
      return lines.joined(separator: "\r\n") + "\r\n"
    }

    static func encodedPowerShellCommand(_ script: String) -> String {
      var data = Data()
      data.reserveCapacity(script.utf16.count * 2)
      for codeUnit in script.utf16 {
        data.append(UInt8(codeUnit & 0x00FF))
        data.append(UInt8(codeUnit >> 8))
      }
      return data.base64EncodedString()
    }

    private static func powerShellLiteral(_ value: String) -> String {
      "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    private func output(_ result: ProcessResult) -> String {
      String(decoding: result.standardOutput + result.standardError, as: UTF8.self)
    }
  }

  public enum StartupManagerError: Error, Equatable, LocalizedError, Sendable {
    case commandFailed(command: String, output: String)
    case missingRuntimeFiles

    public var errorDescription: String? {
      switch self {
      case .commandFailed(let command, let output):
        return "\(command) failed: \(output)"
      case .missingRuntimeFiles:
        return "The packaged Windows helpers do not include Swift runtime DLLs."
      }
    }
  }
#endif
