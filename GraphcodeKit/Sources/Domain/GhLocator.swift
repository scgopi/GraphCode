import Foundation

/// Where to find the GitHub CLI — the dial for Codespace projects
/// (`RemoteProjectLocation.isCodespace`). Unlike `zmx`, `gh` is the human's own
/// install, so this probes the places package managers put it rather than owning a
/// copy: the app and daemon run with launchd's minimal `PATH`, and `Process` never
/// searches `PATH` anyway, so an absolute path is required wherever the invocation is
/// exec'd directly.
public enum GhLocator {
  #if os(Windows)
    /// Windows has no launchd-minimal `PATH` problem, but `Process` still refuses to
    /// search `PATH`, so the same absolute-path rule applies. These are where the
    /// supported installers actually land `gh.exe`: the MSI in Program Files, and
    /// WinGet's per-user shim and package root.
    static var candidates: [String] {
      var paths: [String] = []
      let environment = ProcessInfo.processInfo.environment
      for variable in ["ProgramFiles", "ProgramFiles(x86)"] {
        if let root = environment[variable], !root.isEmpty {
          paths.append("\(root)\\GitHub CLI\\gh.exe")
        }
      }
      if let localAppData = environment["LOCALAPPDATA"], !localAppData.isEmpty {
        paths.append("\(localAppData)\\Microsoft\\WinGet\\Links\\gh.exe")
        paths.append("\(localAppData)\\Programs\\GitHub CLI\\gh.exe")
      }
      paths.append("C:\\Program Files\\GitHub CLI\\gh.exe")
      return paths
    }
  #else
    static let candidates = [
      "/opt/homebrew/bin/gh",
      "/usr/local/bin/gh",
      "/usr/bin/gh",
    ]
  #endif

  /// The first installed candidate. Falls back to the Homebrew path when none is
  /// found, so an invocation built while `gh` is missing still names the place it
  /// would be — the error then reads "no such file" at a path worth installing to,
  /// and `isInstalled` is the up-front check the add-codespace flow uses.
  public static var executablePath: String {
    let candidates = Self.candidates
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? candidates[0]
  }

  public static var isInstalled: Bool {
    candidates.contains { FileManager.default.isExecutableFile(atPath: $0) }
  }
}
