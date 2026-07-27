import Foundation

/// Installs the helpers a shipped `graphcode.app` carries inside itself — `graphcoded` and
/// `zmx` — and loads the daemon, so dragging the app to `/Applications` is the whole
/// installation.
///
/// **Only ever acts on a packaged build.** `make release-dmg` copies the two binaries into
/// `Contents/Resources/bin`; nothing else does. A build run from Xcode has no such
/// directory, so this is a no-op there and a developer's own
/// `make install-zmx install-cli daemon-install` setup — which usually points at
/// DerivedData — is left exactly as it is.
///
/// Re-runs only when the bundled binaries differ from what's installed, tracked by a stamp
/// file. That makes app updates carry daemon updates without a reinstall, and makes
/// ordinary launches cost one small file read.
public enum DaemonBootstrap {
  public enum Outcome: Equatable {
    /// Not a packaged build, so there was nothing to install.
    case notPackaged
    /// Already installed and current.
    case upToDate
    case installed
    case failed(String)
  }

  private static let label = "dev.graphcode.graphcoded"
  /// `graphcode` here is the CLI, not the app — a different product that happens to share
  /// the name a human types. Shipping it matters: `~/.graphcode/bin` is what the README
  /// tells people to put on their PATH, and without this a drag-to-Applications install
  /// would leave that promise unmet.
  private static let helpers = ["graphcoded", "zmx", "graphcode"]

  /// The helpers a packaged app carries, or `nil` when this isn't one.
  static func bundledHelperDirectory(in bundle: Bundle = .main) -> URL? {
    guard let resources = bundle.resourceURL else { return nil }
    let binary = resources.appendingPathComponent("bin", isDirectory: true)
    let allPresent = helpers.allSatisfy {
      FileManager.default.isExecutableFile(atPath: binary.appendingPathComponent($0).path)
    }
    return allPresent ? binary : nil
  }

  static var stampURL: URL {
    SupportDirectory.url.appendingPathComponent("installed-helpers.txt")
  }

  /// Identifies *which* helpers are installed, without hashing megabytes on every launch.
  /// Size plus modification time is enough: these come from a build, so any new copy
  /// differs in at least one.
  static func stamp(forHelpersIn directory: URL) -> String {
    helpers.compactMap { name -> String? in
      let path = directory.appendingPathComponent(name).path
      guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
        let size = attributes[.size] as? Int,
        let modified = attributes[.modificationDate] as? Date
      else { return nil }
      return "\(name):\(size):\(Int(modified.timeIntervalSince1970))"
    }
    .joined(separator: "\n")
  }

  @discardableResult
  public static func installIfNeeded() -> Outcome {
    guard let bundled = bundledHelperDirectory() else { return .notPackaged }

    let expected = stamp(forHelpersIn: bundled)
    let current = try? String(contentsOf: stampURL, encoding: .utf8)
    if current == expected, FileManager.default.fileExists(atPath: launchAgentURL.path) {
      return .upToDate
    }

    do {
      try installHelpers(from: bundled)
      try writeLaunchAgent()
      reloadDaemon()
      try expected.write(to: stampURL, atomically: true, encoding: .utf8)
      return .installed
    } catch {
      return .failed("\(error)")
    }
  }

  private static func installHelpers(from bundled: URL) throws {
    let fileManager = FileManager.default
    let destination = SupportDirectory.binDirectory
    try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

    for name in helpers {
      let target = destination.appendingPathComponent(name)
      // Remove before copying, then re-sign in place. Writing over a path macOS has
      // already validated leaves a stale cached signature and the result is SIGKILLed at
      // exec ("Taskgated Invalid Signature") even though the signature is valid on disk —
      // a near-silent failure, since the binary dies before it can print anything.
      try? fileManager.removeItem(at: target)
      try fileManager.copyItem(at: bundled.appendingPathComponent(name), to: target)
      resign(target)
    }
  }

  private static func resign(_ url: URL) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    process.arguments = ["--force", "--sign", "-", url.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
    process.waitUntilExit()
  }

  static var launchAgentURL: URL {
    URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
      .appendingPathComponent("Library/LaunchAgents/\(label).plist")
  }

  /// Built here rather than shipped as a template file: the two paths it needs are already
  /// known at runtime, and a template would be one more thing to keep in sync.
  static func launchAgentPlist(
    daemonPath: String, supportDirectory: String
  ) -> [String: Any] {
    [
      "Label": label,
      "ProgramArguments": [daemonPath],
      "RunAtLoad": true,
      "KeepAlive": true,
      "StandardOutPath": "\(supportDirectory)/graphcoded.log",
      "StandardErrorPath": "\(supportDirectory)/graphcoded.err.log",
    ]
  }

  private static func writeLaunchAgent() throws {
    let url = launchAgentURL
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let plist = launchAgentPlist(
      daemonPath: SupportDirectory.binDirectory.appendingPathComponent("graphcoded").path,
      supportDirectory: SupportDirectory.url.path)
    let data = try PropertyListSerialization.data(
      fromPropertyList: plist, format: .xml, options: 0)
    try data.write(to: url, options: .atomic)
  }

  /// Unload then load. The unload is what makes an app update actually take: without it,
  /// launchd keeps running the daemon binary it already started, and the freshly installed
  /// one never gets used.
  private static func reloadDaemon() {
    launchctl(["unload", launchAgentURL.path])
    launchctl(["load", launchAgentURL.path])
  }

  private static func launchctl(_ arguments: [String]) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
    process.waitUntilExit()
  }
}
