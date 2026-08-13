import Foundation

#if os(Windows)
  /// Per-user Task Scheduler integration for the Windows daemon. It avoids
  /// elevation and keeps startup state in the user's profile, matching the
  /// current-user named-pipe ACL.
  public struct WindowsStartupManager: StartupManager {
    public let daemonURL: URL
    public let taskName: String
    private let runner: any ProcessRunner

    public init(
      daemonURL: URL = SupportDirectory.binDirectory.appendingPathComponent("graphcoded.exe"),
      taskName: String = "GraphCode\\graphcoded",
      runner: any ProcessRunner = FoundationProcessRunner()
    ) {
      self.daemonURL = daemonURL
      self.taskName = taskName
      self.runner = runner
    }

    public func installAndStart() async throws {
      let create = try await run(
        arguments: [
          "/Create", "/TN", taskName, "/SC", "ONLOGON", "/TR",
          "\"\(daemonURL.path)\"", "/F", "/RL", "LIMITED",
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

    public func stopAndUninstall() async throws {
      let stop = try await run(arguments: ["/End", "/TN", taskName])
      if stop.exitCode != 0, !output(stop).localizedCaseInsensitiveContains("not running") {
        throw StartupManagerError.commandFailed(
          command: "schtasks /End", output: output(stop))
      }
      let delete = try await run(arguments: ["/Delete", "/TN", taskName, "/F"])
      if delete.exitCode != 0, !output(delete).localizedCaseInsensitiveContains("does not exist") {
        throw StartupManagerError.commandFailed(
          command: "schtasks /Delete", output: output(delete))
      }
    }

    public func status() async throws -> StartupStatus {
      let query = try await run(arguments: ["/Query", "/TN", taskName, "/FO", "LIST"])
      guard query.exitCode == 0 else {
        return .notInstalled
      }
      let text = output(query).lowercased()
      return text.contains("running") ? .running : .stopped
    }

    private func run(arguments: [String]) async throws -> ProcessResult {
      let systemRoot =
        ProcessInfo.processInfo.environment["SystemRoot"]
        ?? ProcessInfo.processInfo.environment["WINDIR"]
        ?? "C:\\Windows"
      let executable = URL(fileURLWithPath: systemRoot)
        .appendingPathComponent("System32", isDirectory: true)
        .appendingPathComponent("schtasks.exe")
      return try await runner.run(
        ProcessRequest(executable: executable, arguments: arguments),
        timeout: .seconds(30))
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
