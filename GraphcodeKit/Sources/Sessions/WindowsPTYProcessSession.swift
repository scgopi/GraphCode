import Foundation

#if os(Windows)
  public enum PTYSessionEvent: Sendable, Equatable {
    case output(String)
    case terminated(succeeded: Bool)
  }

  /// Pipe-backed process sessions used by Windows remote SSH launches. Remote commands
  /// do not require a local terminal; keeping the same small API as the Darwin PTY
  /// implementation lets the shared session launcher carry stdin state transfers without
  /// duplicating its retry and delivery logic.
  public final class PTYProcessSession: @unchecked Sendable {
    public let id = UUID()
    public let events: AsyncStream<PTYSessionEvent>

    private let process: Process
    private let input: FileHandle
    private let continuation: AsyncStream<PTYSessionEvent>.Continuation

    public enum SessionError: Error, Equatable {
      case failedToLaunch
    }

    public init(
      executable: String = "cmd.exe",
      arguments: [String] = [],
      workingDirectory: String? = nil,
      extraEnvironment: [String: String] = [:]
    ) throws {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: executable)
      process.arguments = arguments
      if let workingDirectory {
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
      }
      let inputPipe = Pipe()
      let outputPipe = Pipe()
      process.standardInput = inputPipe
      process.standardOutput = outputPipe
      process.standardError = outputPipe
      var environment = ProcessInfo.processInfo.environment
      for key in environment.keys where AgentEnvironment.isInheritedAgentIdentity(key) {
        environment.removeValue(forKey: key)
      }
      for (key, value) in extraEnvironment {
        environment[key] = value
      }
      process.environment = environment
      do {
        try process.run()
      } catch {
        throw SessionError.failedToLaunch
      }

      self.process = process
      input = inputPipe.fileHandleForWriting
      let (stream, continuation) = AsyncStream<PTYSessionEvent>.makeStream()
      events = stream
      self.continuation = continuation
      Task.detached { [weak process, weak output = outputPipe.fileHandleForReading] in
        guard let output else { return }
        let data = output.readDataToEndOfFile()
        if !data.isEmpty {
          continuation.yield(.output(String(decoding: data, as: UTF8.self)))
        }
        process?.waitUntilExit()
        continuation.yield(.terminated(succeeded: process?.terminationStatus == 0))
        continuation.finish()
      }
    }

    public func sendInput(_ text: String) {
      guard let data = text.data(using: .utf8) else { return }
      try? input.write(contentsOf: data)
    }

    public func terminate() {
      if process.isRunning {
        process.terminate()
      }
    }

    public func waitUntilFinished() async -> Bool {
      await waitCollectingOutput().succeeded
    }

    public func waitCollectingOutput() async -> (succeeded: Bool, output: String) {
      var succeeded = false
      var output = ""
      for await event in events {
        switch event {
        case .output(let chunk):
          output += chunk
        case .terminated(let didSucceed):
          succeeded = didSucceed
        }
      }
      return (succeeded, output)
    }
  }
#endif
