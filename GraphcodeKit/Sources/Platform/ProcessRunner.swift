import Foundation

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
      self.process = process
      do {
        try process.run()
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
    guard outcome == nil else {
      lock.unlock()
      return
    }
    outcome = .success(result)
    let continuation = completion
    completion = nil
    lock.unlock()
    continuation?.resume(returning: result)
  }

  private func finish(error: ProcessRunnerError) {
    lock.lock()
    guard outcome == nil else {
      lock.unlock()
      return
    }
    outcome = .failure(error)
    let continuation = completion
    completion = nil
    let process = process
    lock.unlock()
    if process?.isRunning == true {
      process?.terminate()
    }
    continuation?.resume(throwing: error)
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
