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
  private var process: Process?
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

      let process = Process()
      process.arguments = request.arguments
      process.currentDirectoryURL = request.workingDirectory

      var environment = ProcessInfo.processInfo.environment
      for (key, value) in request.environment {
        environment[key] = value
      }
      process.environment = environment
      process.executableURL = Self.resolveExecutable(
        request.executable,
        environment: environment)

      let stdout = Pipe()
      let stderr = Pipe()
      process.standardOutput = stdout
      process.standardError = stderr
      if request.standardInput != nil {
        process.standardInput = Pipe()
      } else {
        process.standardInput = FileHandle.nullDevice
      }

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
      treeController.prepare()
      self.process = process
      do {
        try process.run()
        processStarted = true
        treeController.attach(to: process)
      } catch {
        lock.unlock()
        finish(error: .launchFailed(String(describing: error)))
        return
      }
      lock.unlock()

      if let input = request.standardInput, let inputPipe = process.standardInput as? Pipe {
        DispatchQueue.global(qos: .utility).async {
          do {
            try inputPipe.fileHandleForWriting.write(contentsOf: input)
            try inputPipe.fileHandleForWriting.close()
          } catch {
            try? inputPipe.fileHandleForWriting.close()
          }
        }
      }

      let group = DispatchGroup()
      let collected = CollectedOutput()

      group.enter()
      DispatchQueue.global(qos: .utility).async {
        collected.stdout = stdout.fileHandleForReading.readDataToEndOfFile()
        group.leave()
      }

      group.enter()
      DispatchQueue.global(qos: .utility).async {
        collected.stderr = stderr.fileHandleForReading.readDataToEndOfFile()
        group.leave()
      }

      group.enter()
      DispatchQueue.global(qos: .utility).async {
        process.waitUntilExit()
        group.leave()
      }

      group.notify(queue: .global(qos: .utility)) { [weak self] in
        guard let self else { return }
        let result = ProcessResult(
          exitCode: process.terminationStatus,
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
}

private final class ProcessTreeController: @unchecked Sendable {
  private let lock = NSLock()
  #if os(Windows)
    private var job: HANDLE?
    private var processHandle: HANDLE?
  #elseif canImport(Darwin)
    private var processGroupID: pid_t?
  #endif
  private var process: Process?

  func prepare() {
    #if os(Windows)
      let job = CreateJobObjectW(nil, nil)
      guard let job else { return }
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
        return
      }
      lock.lock()
      self.job = job
      lock.unlock()
    #endif
  }

  func attach(to process: Process) {
    lock.lock()
    self.process = process
    #if os(Windows)
      guard let job else {
        lock.unlock()
        return
      }
      let handle = OpenProcess(
        DWORD(PROCESS_SET_QUOTA | PROCESS_TERMINATE | PROCESS_QUERY_LIMITED_INFORMATION),
        false,
        DWORD(process.processIdentifier))
      guard let handle else {
        lock.unlock()
        return
      }
      guard AssignProcessToJobObject(job, handle) else {
        _ = CloseHandle(handle)
        _ = CloseHandle(job)
        self.job = nil
        lock.unlock()
        return
      }
      processHandle = handle
    #elseif canImport(Darwin)
      let processGroupID = pid_t(process.processIdentifier)
      if setpgid(processGroupID, processGroupID) == 0 {
        self.processGroupID = processGroupID
      }
    #endif
    lock.unlock()
  }

  func terminate() {
    lock.lock()
    let process = self.process
    #if os(Windows)
      let job = self.job
    #elseif canImport(Darwin)
      let processGroupID = self.processGroupID
    #else
    #endif
    lock.unlock()

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
  }

  func close() {
    lock.lock()
    #if os(Windows)
      let processHandle = self.processHandle
      let job = self.job
      self.processHandle = nil
      self.job = nil
    #endif
    lock.unlock()

    #if os(Windows)
      if let processHandle {
        _ = CloseHandle(processHandle)
      }
      if let job {
        _ = CloseHandle(job)
      }
    #endif
  }
}
