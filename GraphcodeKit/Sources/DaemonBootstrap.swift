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
  private static let appBundleIdentifier = "dev.graphcode.app"
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

  /// Whether every helper is actually present and runnable where it was installed.
  ///
  /// The stamp alone cannot answer this: it records which *bundle* was installed, not
  /// whether the installed copies still exist. A bin directory that lost a helper — an
  /// interrupted install, a hand-run `rm`, a cleanup tool — while the stamp survived
  /// produced an app that reported itself up to date over a missing daemon, forever.
  /// That is the "the beta is corrupted" failure: nothing was corrupt, the bootstrap
  /// just refused to look.
  static func helpersInstalled(in directory: URL = SupportDirectory.binDirectory) -> Bool {
    helpers.allSatisfy {
      FileManager.default.isExecutableFile(atPath: directory.appendingPathComponent($0).path)
    }
  }

  @discardableResult
  public static func installIfNeeded() -> Outcome {
    guard let bundled = bundledHelperDirectory() else { return .notPackaged }

    let expected = stamp(forHelpersIn: bundled)
    let current = try? String(contentsOf: stampURL, encoding: .utf8)
    if current == expected, helpersInstalled(), launchAgentIsCurrent() {
      return .upToDate
    }

    do {
      try installHelpers(from: bundled)
      try writeLaunchAgent()
      reloadDaemon()
      try expected.write(to: stampURL, atomically: true, encoding: .utf8)
      return .installed
    } catch {
      // Written somewhere a human (or a bug report) can find: the app has no console,
      // and a bootstrap that failed silently is how a machine ends up looking
      // "corrupted" with nothing to say why.
      let report = "\(Date().ISO8601Format())  helper install failed: \(error)\n"
      let log = SupportDirectory.url.appendingPathComponent("bootstrap.err.log")
      if let handle = try? FileHandle(forWritingTo: log) {
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(report.utf8))
        try? handle.close()
      } else {
        try? report.write(to: log, atomically: true, encoding: .utf8)
      }
      return .failed("\(error)")
    }
  }

  private static func installHelpers(from bundled: URL) throws {
    let fileManager = FileManager.default
    let destination = SupportDirectory.binDirectory
    try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

    for name in helpers {
      let target = destination.appendingPathComponent(name)
      // Stage the copy next to the target, then swap. The earlier remove-then-copy
      // order meant a copy that failed left neither binary — an interrupted first
      // launch gutted `~/.graphcode/bin`, and with the stamp check above blind to it,
      // every later launch called that state up to date. Staging costs one rename and
      // means the old helper survives until its replacement has fully landed.
      //
      // The swap also gives the target a fresh inode, which preserves the original fix
      // here: writing over a path macOS has already validated leaves a stale cached
      // signature and the result is SIGKILLed at exec ("Taskgated Invalid Signature") —
      // a near-silent failure, since the binary dies before it can print anything.
      //
      // What deliberately does *not* happen anymore: an ad-hoc re-sign. The copy keeps
      // the bundle's own Developer ID signature byte for byte; forcing `--sign -` over
      // it replaced a notarized identity with an anonymous one. Combined with the
      // quarantine flag `copyItem` faithfully carries over from a downloaded install,
      // that produced a quarantined, ad-hoc-signed daemon — which launchd's first spawn
      // on a fresh machine greets with "Apple could not verify 'graphcoded' is free of
      // malware". It looked fine on the build machine only because its quarantine was
      // already marked approved. Clearing the xattr is the install step Finder would
      // have performed had a human dragged the helper out themselves.
      let staged = destination.appendingPathComponent("\(name).new")
      try? fileManager.removeItem(at: staged)
      try fileManager.copyItem(at: bundled.appendingPathComponent(name), to: staged)
      clearQuarantine(staged)
      try? fileManager.removeItem(at: target)
      try fileManager.moveItem(at: staged, to: target)
    }
  }

  /// Drops `com.apple.quarantine` from an installed helper. Failure is ignored: a file
  /// that never had the xattr (a build-machine install) errors with ENOATTR, and that
  /// is the healthy case.
  static func clearQuarantine(_ url: URL) {
    removexattr(url.path, "com.apple.quarantine", 0)
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
      // `graphcoded` is a bare signed executable, not a bundle, so it carries no name of
      // its own. Without this key macOS has nothing to call the agent and falls back to
      // the only name it can read — the one on the signing certificate — which is how
      // Login Items and the "can run in the background" notification came to announce a
      // stranger's personal name to every user. `launchd.plist(5)` names this key as
      // exactly what an app installing a legacy plist should set.
      "AssociatedBundleIdentifiers": [appBundleIdentifier],
    ]
  }

  static func currentLaunchAgentPlist() -> [String: Any] {
    launchAgentPlist(
      daemonPath: SupportDirectory.binDirectory.appendingPathComponent("graphcoded").path,
      supportDirectory: SupportDirectory.url.path)
  }

  /// Whether the installed agent is the one this build would write.
  ///
  /// The check this replaced only asked whether the file existed, which meant a change to
  /// the agent itself reached a machine solely as a side effect of its helper binaries
  /// changing in the same release. Comparing the content makes an agent-only fix — the
  /// naming key above — land on the next launch, and does the same for the next one.
  static func launchAgentIsCurrent(
    at url: URL = launchAgentURL, expected: [String: Any] = currentLaunchAgentPlist()
  ) -> Bool {
    guard let data = try? Data(contentsOf: url),
      let installed = try? PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any]
    else { return false }
    return NSDictionary(dictionary: installed).isEqual(to: expected)
  }

  private static func writeLaunchAgent() throws {
    let url = launchAgentURL
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try PropertyListSerialization.data(
      fromPropertyList: currentLaunchAgentPlist(), format: .xml, options: 0)
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
