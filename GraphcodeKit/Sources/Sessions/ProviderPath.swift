import Foundation

/// Whether a backend's CLI resolves the way a session launch resolves it. Without this a
/// missing CLI produced a session whose shell exited 127 at once while the graph went on
/// reporting the loop as running — or, reported by its pane, as SUCCEEDED.
public enum ProviderPath {
  /// What zsh exits with for a command it cannot find.
  public static let commandNotFoundStatus = 127

  /// The same `-i -l` shell the launches use (`ZmxSessionLauncher.loginShellInvocation`,
  /// `GhosttyTerminalView.interactiveLoginShell`), since a developer's PATH usually comes
  /// from `~/.zshrc`. `whence -p` rather than `command -v`: the launch `exec`s the agent,
  /// which only a file on PATH satisfies, so an alias of the same name must not count.
  public static func probeInvocation(for executable: String) -> [String] {
    #if os(Windows)
      let systemRoot = ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows"
      return [
        URL(fileURLWithPath: systemRoot)
          .appendingPathComponent("System32")
          .appendingPathComponent("where.exe").path,
        executable,
      ]
    #else
      return [
        "/bin/zsh", "-i", "-l", "-c",
        "whence -p -- \(RemoteProjectLocation.shellQuoted(executable)) >/dev/null 2>&1",
      ]
    #endif
  }

  /// `nil` when the shell did not answer in time: a slow `~/.zshrc` says nothing about
  /// PATH, and must never be what stops a loop.
  public static func isOnPath(_ executable: String, deadline: Duration = .seconds(15)) async
    -> Bool?
  {
    if await FoundCache.shared.isFresh(executable) { return true }
    let invocation = probeInvocation(for: executable)
    #if os(Windows)
      let process = Process()
      process.executableURL = URL(fileURLWithPath: invocation[0])
      process.arguments = Array(invocation.dropFirst())
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      do {
        try process.run()
      } catch {
        return nil
      }
      let found = await withDeadline(deadline) {
        await Task.detached {
          process.waitUntilExit()
          return process.terminationStatus == 0
        }.value
      }
      guard let found else {
        if process.isRunning { process.terminate() }
        return nil
      }
      if found { await FoundCache.shared.record(executable) }
      return found
    #else
    guard
      let shell = invocation.first,
      let session = try? PTYProcessSession(
        executable: shell, arguments: Array(invocation.dropFirst()))
    else { return nil }
    guard let found = await withDeadline(deadline, { await session.waitUntilFinished() }) else {
      session.terminate()
      return nil
    }
    if found { await FoundCache.shared.record(executable) }
    return found
    #endif
  }

  /// The failure launching `node` would hit, or `nil`. Always `nil` for a remote project:
  /// its PATH belongs to another machine, which this shell cannot see.
  public static func missingProvider(for node: LoopNode, projectPath: String?) async
    -> LaunchFailure?
  {
    if let projectPath, RemoteProjectLocation.parse(projectPath: projectPath) != nil {
      return nil
    }
    guard let executable = node.backend.executableName else { return nil }
    guard await isOnPath(executable) == false else { return nil }
    return LaunchFailure(executable: executable, backend: node.backend)
  }

  /// Found answers only, and briefly: a daemon loading a graph ensures every unattended
  /// loop at once, and one login shell per loop for the same answer is waste. A missing
  /// CLI is never cached, so the check after a fix sees the fix.
  private actor FoundCache {
    static let shared = FoundCache()
    private static let lifetime: TimeInterval = 300
    private var foundAt: [String: Date] = [:]

    func isFresh(_ executable: String) -> Bool {
      guard let found = foundAt[executable] else { return false }
      return Date().timeIntervalSince(found) < Self.lifetime
    }

    func record(_ executable: String) { foundAt[executable] = Date() }
  }
}
