import Foundation

public struct WindowsShellStrategy: ShellStrategy {
  public var commandPrompt: URL
  public var powerShell: URL

  public init(
    commandPrompt: URL? = nil,
    powerShell: URL? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.commandPrompt = commandPrompt ?? Self.defaultCommandPrompt(environment: environment)
    self.powerShell = powerShell ?? Self.defaultPowerShell(environment: environment)
  }

  public func invocation(
    executable: URL,
    arguments: [String],
    workingDirectory: URL?,
    environment: [String: String]
  ) throws -> ShellInvocation {
    let extensionName = executable.pathExtension.lowercased()
    switch extensionName {
    case "cmd", "bat":
      let command =
        ([Self.quoteCommandPromptArgument(executable.path)]
        + arguments.map(Self.quoteCommandPromptArgument)).joined(separator: " ")
      return ShellInvocation(
        kind: .commandPrompt,
        request: ProcessRequest(
          executable: commandPrompt,
          arguments: ["/d", "/q"],
          workingDirectory: workingDirectory,
          environment: environment,
          standardInput: Data((command + "\r\n").utf8)))
    case "ps1":
      return ShellInvocation(
        kind: .powerShell,
        request: ProcessRequest(
          executable: powerShell,
          arguments: ["-NoLogo", "-NoProfile", "-File", executable.path] + arguments,
          workingDirectory: workingDirectory,
          environment: environment))
    default:
      return ShellInvocation(
        kind: .direct,
        request: ProcessRequest(
          executable: executable,
          arguments: arguments,
          workingDirectory: workingDirectory,
          environment: environment))
    }
  }

  private static func defaultCommandPrompt(environment: [String: String]) -> URL {
    if let configured = environmentValue(["ComSpec", "COMSPEC"], in: environment),
      !configured.isEmpty
    {
      return URL(fileURLWithPath: configured)
    }
    if let systemRoot = environmentValue(["SystemRoot", "WINDIR"], in: environment),
      !systemRoot.isEmpty
    {
      return URL(fileURLWithPath: systemRoot)
        .appendingPathComponent("System32", isDirectory: true)
        .appendingPathComponent("cmd.exe")
    }
    return URL(fileURLWithPath: "cmd.exe")
  }

  private static func defaultPowerShell(environment: [String: String]) -> URL {
    if let configured = environmentValue(["GRAPHCODE_POWERSHELL"], in: environment),
      !configured.isEmpty
    {
      return URL(fileURLWithPath: configured)
    }
    if let programFiles = environmentValue(
      ["ProgramW6432", "ProgramFiles"],
      in: environment),
      !programFiles.isEmpty
    {
      let candidate = URL(fileURLWithPath: programFiles)
        .appendingPathComponent("PowerShell", isDirectory: true)
        .appendingPathComponent("7", isDirectory: true)
        .appendingPathComponent("pwsh.exe")
      if FileManager.default.fileExists(atPath: candidate.path) {
        return candidate
      }
    }
    if let candidate = executableInPath("pwsh.exe", environment: environment) {
      return candidate
    }
    if let systemRoot = environmentValue(["SystemRoot", "WINDIR"], in: environment),
      !systemRoot.isEmpty
    {
      let candidate = URL(fileURLWithPath: systemRoot)
        .appendingPathComponent("System32", isDirectory: true)
        .appendingPathComponent("WindowsPowerShell", isDirectory: true)
        .appendingPathComponent("v1.0", isDirectory: true)
        .appendingPathComponent("powershell.exe")
      if FileManager.default.fileExists(atPath: candidate.path) {
        return candidate
      }
    }
    if let candidate = executableInPath("powershell.exe", environment: environment) {
      return candidate
    }
    return URL(fileURLWithPath: "powershell.exe")
  }

  private static func executableInPath(
    _ executable: String,
    environment: [String: String]
  ) -> URL? {
    guard let path = environmentValue(["PATH"], in: environment) else { return nil }
    for directory in path.split(separator: ";", omittingEmptySubsequences: true) {
      let candidate = URL(fileURLWithPath: String(directory), isDirectory: true)
        .appendingPathComponent(executable)
      if FileManager.default.fileExists(atPath: candidate.path) {
        return candidate
      }
    }
    return nil
  }

  private static func quoteCommandPromptArgument(_ value: String) -> String {
    var quoted = "\""
    for character in value {
      if "^&|<>()!%".contains(character) {
        quoted.append("^")
      }
      if character == "\"" {
        quoted.append("^")
      }
      quoted.append(character)
    }
    quoted.append("\"")
    return quoted
  }
}
public struct DarwinShellStrategy: ShellStrategy {
  public var shell: URL

  public init(shell: URL = URL(fileURLWithPath: "/bin/zsh")) {
    self.shell = shell
  }

  public func invocation(
    executable: URL,
    arguments: [String],
    workingDirectory: URL?,
    environment: [String: String]
  ) throws -> ShellInvocation {
    ShellInvocation(
      kind: .posix,
      request: ProcessRequest(
        executable: shell,
        arguments: [
          "-l", "-c", ([executable.path] + arguments).map(Self.quote).joined(separator: " "),
        ],
        workingDirectory: workingDirectory,
        environment: environment))
  }

  private static func quote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}

public struct DirectShellStrategy: ShellStrategy {
  public init() {}

  public func invocation(
    executable: URL,
    arguments: [String],
    workingDirectory: URL?,
    environment: [String: String]
  ) throws -> ShellInvocation {
    ShellInvocation(
      kind: .direct,
      request: ProcessRequest(
        executable: executable,
        arguments: arguments,
        workingDirectory: workingDirectory,
        environment: environment))
  }
}

#if os(Windows)
  public typealias DefaultShellStrategy = WindowsShellStrategy
#else
  public typealias DefaultShellStrategy = DarwinShellStrategy
#endif

public typealias PosixShellStrategy = DarwinShellStrategy
private func environmentValue(_ keys: [String], in environment: [String: String]) -> String? {
  for key in keys {
    if let value = environment[key] {
      return value
    }
  }
  for (key, value) in environment
  where keys.contains(where: { $0.caseInsensitiveCompare(key) == .orderedSame }) {
    return value
  }
  return nil
}
