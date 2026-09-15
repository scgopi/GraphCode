/// Why the daemon stopped a loop whose backend CLI the launch shell could not find.
import Foundation

public struct LaunchFailure: Codable, Equatable, Sendable {
  public var executable: String
  public var backend: CLISessionBackendKind
  public var occurredAt: Date

  public init(executable: String, backend: CLISessionBackendKind, occurredAt: Date = Date()) {
    self.executable = executable
    self.backend = backend
    self.occurredAt = occurredAt
  }

  public var title: String { "\(executable) is not on your PATH" }

  public var message: String {
    #if os(Windows)
      return
        "GraphCode couldn't find \(executable), the \(backend.displayName) command-line tool, "
        + "so the loop was stopped instead of left running without an agent. Install "
        + "\(backend.displayName), add the folder containing \(executable) to your user PATH, "
        + "then restart the loop."
    #else
      return
        "GraphCode couldn't find \(executable), the \(backend.displayName) command-line tool, so "
        + "the loop was stopped instead of left running without an agent. Loops start their "
        + "agent from a login shell (/bin/zsh -i -l): install \(backend.displayName), or add "
        + "the folder containing \(executable) to PATH in ~/.zshrc or ~/.zprofile, then "
        + "restart the loop."
    #endif
  }
}
