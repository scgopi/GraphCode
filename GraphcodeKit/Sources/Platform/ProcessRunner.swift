import Foundation

#if canImport(Darwin)
  import Darwin
#endif

#if os(Windows)
  import WinSDK
#endif

public enum ProcessRunnerError: Error, Equatable, LocalizedError, Sendable {
  case emptyExecutable
  case launchFailed(String)
  case timedOut
  case cancelled

  public var errorDescription: String? {
    switch self {
    case .emptyExecutable:
      return "No executable was provided."
    case .launchFailed(let message):
      return "The process could not be launched: \(message)"
    case .timedOut:
      return "The process exceeded its timeout."
    case .cancelled:
      return "The process was cancelled."
    }
  }
}
public struct FoundationProcessRunner: ProcessRunner {
  private let beforeStart: (@Sendable () async -> Void)?

  public init() {
    beforeStart = nil
  }

  init(beforeStart: @escaping @Sendable () async -> Void) {
    self.beforeStart = beforeStart
  }

  public func run(_ request: ProcessRequest, timeout: Duration? = nil) async throws -> ProcessResult
  {
    guard !request.executable.path.isEmpty else {
      throw ProcessRunnerError.emptyExecutable
    }

    let execution = ProcessExecution(request: request)
    let timeoutTask = timeout.map { duration in
      Task {
        do {
          try await Task.sleep(for: duration)
          execution.timeout()
        } catch {
          // The timeout task is cancelled when the process finishes.
        }
      }
    }
    defer { timeoutTask?.cancel() }

    return try await withTaskCancellationHandler {
      if let beforeStart {
        await beforeStart()
      }
      return try await execution.start()
    } onCancel: {
      execution.cancel()
    }
  }
}
public typealias DefaultProcessRunner = FoundationProcessRunner
public typealias WindowsProcessRunner = FoundationProcessRunner
private final class ProcessExecution: @unchecked Sendable {
  private let request: ProcessRequest
  private let lock = NSLock()
  private var process: PlatformProcess?
  private var completion: CheckedContinuation<ProcessResult, Error>?
  private var outcome: Result<ProcessResult, ProcessRunnerError>?
  private let treeController = ProcessTreeController()
  private var processStarted = false

  init(request: ProcessRequest) {
    self.request = request
  }

  func start() async throws -> ProcessResult {
    try await withCheckedThrowingContinuation { continuation in
      lock.lock()
      if let outcome {
        lock.unlock()
        switch outcome {
        case .success(let result):
          continuation.resume(returning: result)
        case .failure(let error):
          continuation.resume(throwing: error)
        }
        return
      }
      completion = continuation
      lock.unlock()

      var environment = ProcessInfo.processInfo.environment
      for (key, value) in request.environment {
        environment[key] = value
      }
      var launchRequest = request
      launchRequest.environment = environment
      launchRequest.executable = Self.resolveExecutable(
        request.executable,
        environment: environment)

      lock.lock()
      if outcome != nil {
        lock.unlock()
        return
      }
      if Task.isCancelled {
        lock.unlock()
        finish(error: .cancelled)
        return
      }

      let process: PlatformProcess
      do {
        process = try treeController.launch(launchRequest)
        self.process = process
        processStarted = true
      } catch let error as ProcessRunnerError {
        lock.unlock()
        finish(error: error)
        return
      } catch {
        lock.unlock()
        finish(error: .launchFailed(String(describing: error)))
        return
      }
      lock.unlock()

      if let input = request.standardInput, let inputPipe = process.standardInput {
        DispatchQueue.global(qos: .utility).async {
          inputPipe.write(input)
        }
      }

      let group = DispatchGroup()
      let collected = CollectedOutput()
      let termination = TerminationStatus()

      group.enter()
      DispatchQueue.global(qos: .utility).async {
        collected.stdout = process.standardOutput.readDataToEndOfFile()
        group.leave()
      }

      group.enter()
      DispatchQueue.global(qos: .utility).async {
        collected.stderr = process.standardError.readDataToEndOfFile()
        group.leave()
      }

      group.enter()
      DispatchQueue.global(qos: .utility).async {
        termination.code = process.waitUntilExit()
        self.treeController.rootDidExit()
        group.leave()
      }

      group.notify(queue: .global(qos: .utility)) { [weak self] in
        guard let self else { return }
        let result = ProcessResult(
          exitCode: termination.code,
          standardOutput: collected.stdout,
          standardError: collected.stderr)
        self.finish(result: result)
      }
    }
  }

  func timeout() {
    finish(error: .timedOut)
  }

  func cancel() {
    finish(error: .cancelled)
  }

  private func finish(result: ProcessResult) {
    lock.lock()
    if case .failure(let error) = outcome {
      let continuation = completion
      completion = nil
      lock.unlock()
      treeController.close()
      continuation?.resume(throwing: error)
      return
    }
    guard outcome == nil else {
      lock.unlock()
      return
    }
    outcome = .success(result)
    let continuation = completion
    completion = nil
    lock.unlock()
    treeController.close()
    continuation?.resume(returning: result)
  }

  private func finish(error: ProcessRunnerError) {
    lock.lock()
    guard outcome == nil else {
      lock.unlock()
      return
    }
    outcome = .failure(error)
    let processStarted = processStarted
    let continuation: CheckedContinuation<ProcessResult, Error>?
    if processStarted {
      continuation = nil
    } else {
      continuation = completion
      completion = nil
    }
    lock.unlock()
    if processStarted {
      treeController.terminate()
    } else {
      treeController.close()
      continuation?.resume(throwing: error)
    }
  }

  private static func resolveExecutable(
    _ executable: URL,
    environment: [String: String]
  ) -> URL {
    let path = executable.path
    guard !path.contains("/"), !path.contains("\\"),
      !path.contains(":"),
      let pathValue = environment.first(where: {
        $0.key.caseInsensitiveCompare("PATH") == .orderedSame
      })?.value
    else {
      return executable
    }

    let candidates =
      pathValue
      .split(separator: ";", omittingEmptySubsequences: true)
      .map(String.init)
      .map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent(path) }
    if let candidate = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) })
    {
      return candidate
    }
    return executable
  }

  private final class CollectedOutput: @unchecked Sendable {
    var stdout = Data()
    var stderr = Data()
  }

  private final class TerminationStatus: @unchecked Sendable {
    var code: Int32 = -1
  }
}
private final class ProcessTreeController: @unchecked Sendable {
  private let lock = NSLock()
  private var process: PlatformProcess?
  #if os(Windows)
    private var job: HANDLE?
  #elseif canImport(Darwin)
    private var processGroupID: pid_t?
  #endif

  func launch(_ request: ProcessRequest) throws -> PlatformProcess {
    lock.lock()
    defer { lock.unlock() }
    #if os(Windows)
      let job = try makeWindowsJob()
      self.job = job
      do {
        let process = try PlatformProcess.launchWindows(request, job: job)
        self.process = process
        return process
      } catch {
        _ = CloseHandle(job)
        self.job = nil
        throw error
      }
    #elseif canImport(Darwin)
      let launched = try PlatformProcess.launchDarwin(request)
      processGroupID = launched.processID
      process = launched
      return launched
    #else
      let launched = try PlatformProcess.launchFoundation(request)
      process = launched
      return launched
    #endif
  }

  func terminate() {
    lock.lock()
    #if os(Windows)
      if let job {
        _ = TerminateJobObject(job, 1)
      } else {
        process?.terminate()
      }
    #elseif canImport(Darwin)
      if let processGroupID {
        _ = kill(-processGroupID, SIGTERM)
        _ = kill(-processGroupID, SIGKILL)
      } else {
        process?.terminate()
      }
    #else
      process?.terminate()
    #endif
    lock.unlock()
  }

  func rootDidExit() {
    #if os(Windows)
      lock.lock()
      if let job {
        _ = TerminateJobObject(job, 0)
        _ = CloseHandle(job)
        self.job = nil
      }
      lock.unlock()
    #elseif canImport(Darwin)
      lock.lock()
      if let processGroupID {
        Self.terminateDarwinProcessGroup(processGroupID)
      }
      lock.unlock()
    #endif
  }

  func close() {
    lock.lock()
    let process = self.process
    self.process = nil
    #if os(Windows)
      let job = self.job
      self.job = nil
    #elseif canImport(Darwin)
      let processGroupID = self.processGroupID
      self.processGroupID = nil
    #endif
    #if canImport(Darwin)
      if let processGroupID {
        Self.terminateDarwinProcessGroup(processGroupID)
      }
    #endif
    process?.close()
    #if os(Windows)
      if let job {
        _ = CloseHandle(job)
      }
    #endif
    lock.unlock()
  }

  #if canImport(Darwin)
    private static func terminateDarwinProcessGroup(_ processGroupID: pid_t) {
      guard processGroupID > 0 else { return }
      _ = kill(-processGroupID, SIGTERM)
      _ = kill(-processGroupID, SIGKILL)
    }
  #endif

  #if os(Windows)
    private func makeWindowsJob() throws -> HANDLE {
      guard let job = CreateJobObjectW(nil, nil) else {
        throw ProcessRunnerError.launchFailed("CreateJobObjectW failed")
      }
      var limits = JOBOBJECT_EXTENDED_LIMIT_INFORMATION()
      limits.BasicLimitInformation.LimitFlags = DWORD(JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE)
      let configured = withUnsafeMutablePointer(to: &limits) {
        SetInformationJobObject(
          job,
          JobObjectExtendedLimitInformation,
          $0,
          DWORD(MemoryLayout<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>.size))
      }
      guard configured else {
        _ = CloseHandle(job)
        throw ProcessRunnerError.launchFailed("SetInformationJobObject failed")
      }
      return job
    }
  #endif
}
private final class PlatformProcess: @unchecked Sendable {
  let standardOutput: ProcessPipe
  let standardError: ProcessPipe
  let standardInput: ProcessPipe?
  #if os(Windows)
    private let processHandle: HANDLE
  #elseif canImport(Darwin)
    let processID: pid_t
  #else
    private let foundationProcess: Process
  #endif

  #if os(Windows)
    private init(
      standardOutput: ProcessPipe,
      standardError: ProcessPipe,
      standardInput: ProcessPipe?,
      processHandle: HANDLE
    ) {
      self.standardOutput = standardOutput
      self.standardError = standardError
      self.standardInput = standardInput
      self.processHandle = processHandle
    }
  #elseif canImport(Darwin)
    private init(
      standardOutput: ProcessPipe,
      standardError: ProcessPipe,
      standardInput: ProcessPipe?,
      processID: pid_t
    ) {
      self.standardOutput = standardOutput
      self.standardError = standardError
      self.standardInput = standardInput
      self.processID = processID
    }
  #else
    private init(
      standardOutput: ProcessPipe,
      standardError: ProcessPipe,
      standardInput: ProcessPipe?,
      foundationProcess: Process
    ) {
      self.standardOutput = standardOutput
      self.standardError = standardError
      self.standardInput = standardInput
      self.foundationProcess = foundationProcess
    }
  #endif

  func waitUntilExit() -> Int32 {
    #if os(Windows)
      _ = WaitForSingleObject(processHandle, INFINITE)
      var code: DWORD = 1
      _ = GetExitCodeProcess(processHandle, &code)
      return Int32(bitPattern: code)
    #elseif canImport(Darwin)
      var status: Int32 = 0
      while waitpid(processID, &status, 0) == -1, errno == EINTR {}
      if status & 0x7f == 0 {
        return (status >> 8) & 0xff
      }
      let terminatingSignal = status & 0x7f
      if terminatingSignal != 0, terminatingSignal != 0x7f {
        return 128 + terminatingSignal
      }
      return 1
    #else
      foundationProcess.waitUntilExit()
      return foundationProcess.terminationStatus
    #endif
  }

  func terminate() {
    #if os(Windows)
      _ = TerminateProcess(processHandle, 1)
    #elseif canImport(Darwin)
      _ = kill(processID, SIGKILL)
    #else
      foundationProcess.terminate()
    #endif
  }

  func close() {
    standardOutput.close()
    standardError.close()
    standardInput?.close()
    #if os(Windows)
      _ = CloseHandle(processHandle)
    #endif
  }

  #if os(Windows)
    static func launchWindows(_ request: ProcessRequest, job: HANDLE) throws -> PlatformProcess {
      var security = SECURITY_ATTRIBUTES()
      security.nLength = DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size)
      security.bInheritHandle = true

      var stdinRead: HANDLE?
      var stdinWrite: HANDLE?
      var stdoutRead: HANDLE?
      var stdoutWrite: HANDLE?
      var stderrRead: HANDLE?
      var stderrWrite: HANDLE?
      guard CreatePipe(&stdinRead, &stdinWrite, &security, 0),
        CreatePipe(&stdoutRead, &stdoutWrite, &security, 0),
        CreatePipe(&stderrRead, &stderrWrite, &security, 0),
        let stdinRead,
        let stdinWrite,
        let stdoutRead,
        let stdoutWrite,
        let stderrRead,
        let stderrWrite
      else {
        closeWindowsHandles(stdinRead, stdinWrite, stdoutRead, stdoutWrite, stderrRead, stderrWrite)
        throw ProcessRunnerError.launchFailed("CreatePipe failed")
      }

      func closeParentHandles() {
        _ = CloseHandle(stdinRead)
        _ = CloseHandle(stdoutWrite)
        _ = CloseHandle(stderrWrite)
      }

      guard SetHandleInformation(stdinWrite, DWORD(HANDLE_FLAG_INHERIT), 0),
        SetHandleInformation(stdoutRead, DWORD(HANDLE_FLAG_INHERIT), 0),
        SetHandleInformation(stderrRead, DWORD(HANDLE_FLAG_INHERIT), 0)
      else {
        closeWindowsHandles(stdinRead, stdinWrite, stdoutRead, stdoutWrite, stderrRead, stderrWrite)
        throw ProcessRunnerError.launchFailed("SetHandleInformation failed")
      }

      var startup = STARTUPINFOEXW()
      startup.StartupInfo.cb = DWORD(MemoryLayout<STARTUPINFOEXW>.size)
      startup.StartupInfo.dwFlags = DWORD(STARTF_USESTDHANDLES)
      startup.StartupInfo.hStdInput = stdinRead
      startup.StartupInfo.hStdOutput = stdoutWrite
      startup.StartupInfo.hStdError = stderrWrite
      var attributeSize: SIZE_T = 0
      _ = InitializeProcThreadAttributeList(nil, 1, 0, &attributeSize)
      guard attributeSize > 0 else {
        closeWindowsHandles(stdinRead, stdinWrite, stdoutRead, stdoutWrite, stderrRead, stderrWrite)
        throw ProcessRunnerError.launchFailed("InitializeProcThreadAttributeList sizing failed")
      }
      let attributeMemory = UnsafeMutableRawPointer.allocate(
        byteCount: Int(attributeSize),
        alignment: MemoryLayout<UInt64>.alignment)
      let attributeList = OpaquePointer(attributeMemory)
      guard InitializeProcThreadAttributeList(attributeList, 1, 0, &attributeSize) else {
        attributeMemory.deallocate()
        closeWindowsHandles(stdinRead, stdinWrite, stdoutRead, stdoutWrite, stderrRead, stderrWrite)
        throw ProcessRunnerError.launchFailed("InitializeProcThreadAttributeList failed")
      }
      defer {
        DeleteProcThreadAttributeList(attributeList)
        attributeMemory.deallocate()
      }
      var inheritedHandles = [stdinRead, stdoutWrite, stderrWrite]
      let handlesConfigured = inheritedHandles.withUnsafeMutableBufferPointer { handles in
        UpdateProcThreadAttribute(
          attributeList,
          0,
          DWORD_PTR(0x0002_0002),
          handles.baseAddress,
          SIZE_T(MemoryLayout<HANDLE>.stride * handles.count),
          nil,
          nil)
      }
      guard handlesConfigured else {
        closeWindowsHandles(stdinRead, stdinWrite, stdoutRead, stdoutWrite, stderrRead, stderrWrite)
        throw ProcessRunnerError.launchFailed("UpdateProcThreadAttribute failed")
      }
      startup.lpAttributeList = attributeList
      var processInfo = PROCESS_INFORMATION()
      var application = wideString(request.executable.path)
      var commandLine = wideString(windowsCommandLine(request))
      let workingDirectory = request.workingDirectory.map { wideString($0.path) }
      var environment = wideEnvironment(request.environment)
      let flags = DWORD(
        CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT | EXTENDED_STARTUPINFO_PRESENT)

      func createProcess(_ workingDirectory: UnsafeMutablePointer<UInt16>?) -> Bool {
        application.withUnsafeMutableBufferPointer { application in
          commandLine.withUnsafeMutableBufferPointer { commandLine in
            environment.withUnsafeMutableBufferPointer { environment in
              CreateProcessW(
                application.baseAddress,
                commandLine.baseAddress,
                nil,
                nil,
                true,
                flags,
                UnsafeMutableRawPointer(environment.baseAddress),
                workingDirectory,
                &startup.StartupInfo,
                &processInfo)
            }
          }
        }
      }
      let created: Bool
      if var workingDirectory {
        created = workingDirectory.withUnsafeMutableBufferPointer {
          createProcess($0.baseAddress)
        }
      } else {
        created = createProcess(nil)
      }
      guard created else {
        closeParentHandles()
        _ = CloseHandle(stdinWrite)
        _ = CloseHandle(stdoutRead)
        _ = CloseHandle(stderrRead)
        _ = CloseHandle(processInfo.hThread)
        _ = CloseHandle(processInfo.hProcess)
        throw ProcessRunnerError.launchFailed("CreateProcessW failed")
      }

      guard AssignProcessToJobObject(job, processInfo.hProcess) else {
        _ = TerminateProcess(processInfo.hProcess, 1)
        _ = CloseHandle(processInfo.hThread)
        _ = CloseHandle(processInfo.hProcess)
        closeParentHandles()
        _ = CloseHandle(stdinWrite)
        _ = CloseHandle(stdoutRead)
        _ = CloseHandle(stderrRead)
        throw ProcessRunnerError.launchFailed("AssignProcessToJobObject failed")
      }
      guard ResumeThread(processInfo.hThread) != DWORD.max else {
        _ = TerminateProcess(processInfo.hProcess, 1)
        _ = CloseHandle(processInfo.hThread)
        _ = CloseHandle(processInfo.hProcess)
        closeParentHandles()
        _ = CloseHandle(stdinWrite)
        _ = CloseHandle(stdoutRead)
        _ = CloseHandle(stderrRead)
        throw ProcessRunnerError.launchFailed("ResumeThread failed")
      }

      _ = CloseHandle(processInfo.hThread)
      closeParentHandles()
      let input: ProcessPipe?
      if request.standardInput == nil {
        _ = CloseHandle(stdinWrite)
        input = nil
      } else {
        input = ProcessPipe(handle: stdinWrite)
      }
      let output = ProcessPipe(handle: stdoutRead)
      let error = ProcessPipe(handle: stderrRead)
      return PlatformProcess(
        standardOutput: output,
        standardError: error,
        standardInput: input,
        processHandle: processInfo.hProcess)
    }

    private static func wideString(_ value: String) -> [UInt16] {
      Array(value.utf16) + [0]
    }

    private static func wideEnvironment(_ environment: [String: String]) -> [UInt16] {
      environment.keys.sorted().map { "\($0)=\(environment[$0] ?? "")" }
        .joined(separator: "\0")
        .utf16
        + [0, 0]
    }

    private static func quoteWindowsArgument(_ value: String) -> String {
      var result = "\""
      var backslashes = 0
      for character in value {
        if character == "\\" {
          backslashes += 1
        } else if character == "\"" {
          result += String(repeating: "\\", count: backslashes * 2 + 1)
          result.append(character)
          backslashes = 0
        } else {
          result += String(repeating: "\\", count: backslashes)
          result.append(character)
          backslashes = 0
        }
      }
      result += String(repeating: "\\", count: backslashes * 2)
      result.append("\"")
      return result
    }

    private static func windowsCommandLine(_ request: ProcessRequest) -> String {
      let executable = quoteWindowsArgument(
        request.executable.path.replacingOccurrences(of: "/", with: "\\"))
      guard request.executable.lastPathComponent.lowercased() == "cmd.exe",
        let commandIndex = request.arguments.firstIndex(where: {
          $0.caseInsensitiveCompare("/c") == .orderedSame
            || $0.caseInsensitiveCompare("/k") == .orderedSame
        }),
        commandIndex + 1 < request.arguments.count
      else {
        return ([executable] + request.arguments.map(quoteWindowsArgument))
          .joined(separator: " ")
      }

      let options = request.arguments[..<commandIndex].joined(separator: " ")
      let command = request.arguments[(commandIndex + 1)...].joined(separator: " ")
      return
        ([executable, options, request.arguments[commandIndex], "\"\(command)\""]
        .filter { !$0.isEmpty })
        .joined(separator: " ")
    }

    private static func closeWindowsHandles(_ handles: HANDLE?...) {
      for handle in handles {
        if let handle {
          _ = CloseHandle(handle)
        }
      }
    }
  #elseif canImport(Darwin)
    static func launchDarwin(_ request: ProcessRequest) throws -> PlatformProcess {
      let inputPipe = request.standardInput.map { _ in Pipe() }
      let outputPipe = Pipe()
      let errorPipe = Pipe()
      let nullInput = inputPipe == nil ? open("/dev/null", O_RDONLY) : -1
      guard inputPipe != nil || nullInput >= 0 else {
        throw ProcessRunnerError.launchFailed("Could not open /dev/null")
      }

      var actions: posix_spawn_file_actions_t?
      guard posix_spawn_file_actions_init(&actions) == 0 else {
        if nullInput >= 0 { _ = Darwin.close(nullInput) }
        throw ProcessRunnerError.launchFailed("posix_spawn file actions initialization failed")
      }
      defer { posix_spawn_file_actions_destroy(&actions) }

      let inputRead = inputPipe?.fileHandleForReading.fileDescriptor ?? nullInput
      let inputWrite = inputPipe?.fileHandleForWriting.fileDescriptor
      let outputRead = outputPipe.fileHandleForReading.fileDescriptor
      let outputWrite = outputPipe.fileHandleForWriting.fileDescriptor
      let errorRead = errorPipe.fileHandleForReading.fileDescriptor
      let errorWrite = errorPipe.fileHandleForWriting.fileDescriptor
      func closePipes() {
        try? inputPipe?.fileHandleForReading.close()
        try? inputPipe?.fileHandleForWriting.close()
        try? outputPipe.fileHandleForReading.close()
        try? outputPipe.fileHandleForWriting.close()
        try? errorPipe.fileHandleForReading.close()
        try? errorPipe.fileHandleForWriting.close()
        if nullInput >= 0 { _ = Darwin.close(nullInput) }
      }
      guard posix_spawn_file_actions_adddup2(&actions, inputRead, STDIN_FILENO) == 0,
        posix_spawn_file_actions_adddup2(&actions, outputWrite, STDOUT_FILENO) == 0,
        posix_spawn_file_actions_adddup2(&actions, errorWrite, STDERR_FILENO) == 0,
        posix_spawn_file_actions_addclose(&actions, inputRead) == 0,
        posix_spawn_file_actions_addclose(&actions, outputRead) == 0,
        posix_spawn_file_actions_addclose(&actions, outputWrite) == 0,
        posix_spawn_file_actions_addclose(&actions, errorRead) == 0,
        posix_spawn_file_actions_addclose(&actions, errorWrite) == 0
      else {
        closePipes()
        throw ProcessRunnerError.launchFailed("posix_spawn file action failed")
      }
      if let inputWrite {
        guard posix_spawn_file_actions_addclose(&actions, inputWrite) == 0 else {
          closePipes()
          throw ProcessRunnerError.launchFailed("posix_spawn file action failed")
        }
      }
      if let workingDirectory = request.workingDirectory {
        let changedDirectory = workingDirectory.path.withCString {
          posix_spawn_file_actions_addchdir_np(&actions, $0)
        }
        guard changedDirectory == 0 else {
          closePipes()
          throw ProcessRunnerError.launchFailed("posix_spawn working-directory setup failed")
        }
      }

      var attributes: posix_spawnattr_t?
      guard posix_spawnattr_init(&attributes) == 0 else {
        closePipes()
        throw ProcessRunnerError.launchFailed("posix_spawn attributes initialization failed")
      }
      defer { posix_spawnattr_destroy(&attributes) }
      let flags = Int16(POSIX_SPAWN_SETPGROUP)
      guard posix_spawnattr_setflags(&attributes, flags) == 0,
        posix_spawnattr_setpgroup(&attributes, 0) == 0
      else {
        closePipes()
        throw ProcessRunnerError.launchFailed("posix_spawn process-group setup failed")
      }

      let arguments = [request.executable.path] + request.arguments
      var argv = arguments.map { strdupString($0) } + [nil]
      var environment =
        request.environment.keys.sorted().map {
          strdupString("\($0)=\(request.environment[$0] ?? "")")
        } + [nil]
      defer {
        for pointer in argv {
          if let pointer { free(pointer) }
        }
        for pointer in environment {
          if let pointer { free(pointer) }
        }
      }

      var processID: pid_t = 0
      let result = request.executable.path.withCString { executable in
        argv.withUnsafeMutableBufferPointer { argv in
          environment.withUnsafeMutableBufferPointer { environment in
            posix_spawn(
              &processID,
              executable,
              &actions,
              &attributes,
              argv.baseAddress,
              environment.baseAddress)
          }
        }
      }
      guard result == 0 else {
        closePipes()
        throw ProcessRunnerError.launchFailed(String(cString: strerror(result)))
      }

      if nullInput >= 0 {
        _ = Darwin.close(nullInput)
      }
      try? inputPipe?.fileHandleForReading.close()
      try? outputPipe.fileHandleForWriting.close()
      try? errorPipe.fileHandleForWriting.close()
      return PlatformProcess(
        standardOutput: ProcessPipe(fileHandle: outputPipe.fileHandleForReading),
        standardError: ProcessPipe(fileHandle: errorPipe.fileHandleForReading),
        standardInput: inputPipe.map {
          ProcessPipe(fileHandle: $0.fileHandleForWriting)
        },
        processID: processID)
    }
  #else
    static func launchFoundation(_ request: ProcessRequest) throws -> PlatformProcess {
      let process = Process()
      process.arguments = request.arguments
      process.currentDirectoryURL = request.workingDirectory
      process.environment = request.environment
      process.executableURL = request.executable

      let outputPipe = Pipe()
      let errorPipe = Pipe()
      process.standardOutput = outputPipe
      process.standardError = errorPipe
      let inputPipe = request.standardInput == nil ? nil : Pipe()
      process.standardInput = inputPipe ?? FileHandle.nullDevice
      do {
        try process.run()
      } catch {
        throw ProcessRunnerError.launchFailed(String(describing: error))
      }
      return PlatformProcess(
        standardOutput: ProcessPipe(fileHandle: outputPipe.fileHandleForReading),
        standardError: ProcessPipe(fileHandle: errorPipe.fileHandleForReading),
        standardInput: inputPipe.map {
          ProcessPipe(fileHandle: $0.fileHandleForWriting)
        },
        foundationProcess: process)
    }
  #endif

  #if canImport(Darwin)
    private static func strdupString(_ value: String) -> UnsafeMutablePointer<CChar>? {
      value.withCString { strdup($0) }
    }
  #endif
}
private final class ProcessPipe: @unchecked Sendable {
  #if os(Windows)
    private let lock = NSLock()
    private let handle: HANDLE
    private var closed = false

    init(handle: HANDLE) {
      self.handle = handle
    }

    func readDataToEndOfFile() -> Data {
      var data = Data()
      var buffer = [UInt8](repeating: 0, count: 16 * 1024)
      while true {
        var count: DWORD = 0
        let succeeded = buffer.withUnsafeMutableBytes { bytes in
          ReadFile(handle, bytes.baseAddress, DWORD(bytes.count), &count, nil)
        }
        if !succeeded || count == 0 {
          break
        }
        data.append(contentsOf: buffer[0..<Int(count)])
      }
      close()
      return data
    }

    func write(_ data: Data) {
      data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
          var written: DWORD = 0
          let pointer = bytes.baseAddress!.advanced(by: offset)
          guard WriteFile(handle, pointer, DWORD(bytes.count - offset), &written, nil),
            written > 0
          else {
            break
          }
          offset += Int(written)
        }
      }
      close()
    }

    func close() {
      lock.lock()
      guard !closed else {
        lock.unlock()
        return
      }
      closed = true
      lock.unlock()
      _ = CloseHandle(handle)
    }
  #else
    private let fileHandle: FileHandle

    init(fileHandle: FileHandle) {
      self.fileHandle = fileHandle
    }

    func readDataToEndOfFile() -> Data {
      let data = fileHandle.readDataToEndOfFile()
      close()
      return data
    }

    func write(_ data: Data) {
      do {
        try fileHandle.write(contentsOf: data)
      } catch {
        // The process may have exited before all input was written.
      }
      close()
    }

    func close() {
      try? fileHandle.close()
    }
  #endif
}
