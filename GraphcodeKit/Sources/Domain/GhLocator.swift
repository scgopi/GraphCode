import Foundation

/// Where to find the GitHub CLI — the dial for Codespace projects
/// (`RemoteProjectLocation.isCodespace`). Unlike `zmx`, `gh` is the human's own
/// install, so this probes the places package managers put it rather than owning a
/// copy: the app and daemon run with launchd's minimal `PATH`, and `Process` never
/// searches `PATH` anyway, so an absolute path is required wherever the invocation is
/// exec'd directly.
public enum GhLocator {
  static let candidates = [
    "/opt/homebrew/bin/gh",
    "/usr/local/bin/gh",
    "/usr/bin/gh",
  ]

  /// The first installed candidate. Falls back to the Homebrew path when none is
  /// found, so an invocation built while `gh` is missing still names the place it
  /// would be — the error then reads "no such file" at a path worth installing to,
  /// and `isInstalled` is the up-front check the add-codespace flow uses.
  public static var executablePath: String {
    candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? candidates[0]
  }

  public static var isInstalled: Bool {
    candidates.contains { FileManager.default.isExecutableFile(atPath: $0) }
  }
}
