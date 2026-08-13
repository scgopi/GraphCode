import Foundation

#if canImport(Darwin)

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
    if current == expected, FileManager.default.fileExists(atPath: launchAgentURL.path),
      helpersInstalled()
    {
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

#else

/// Windows helper installation and per-user startup registration.
import WinSDK

public enum DaemonBootstrap {
  public enum Outcome: Equatable {
    case notPackaged
    case upToDate
    case installed
    case failed(String)
  }

  private static let helpers = ["graphcoded.exe", "graphcode.exe"]
  private static let versionFile = ".graphcode-package.version"

  public static func installIfNeeded() -> Outcome {
    guard let bundled = bundledHelperDirectory(in: .main) else {
      return .notPackaged
    }

    let destination = SupportDirectory.binDirectory
    let manager = WindowsStartupManager(
      daemonURL: destination.appendingPathComponent("graphcoded.exe"))
    do {
      let packageVersion = try packageVersion(for: bundled)
      let status = try awaitBlocking { try await manager.status() }
      let installedCurrent =
        installedPackageVersion(in: destination) == packageVersion
        && helpersInstalled(in: destination)
      if installedCurrent {
        if status == .running {
          return .upToDate
        }
        try awaitBlocking {
          try await manager.installAndStart()
        }
        return .installed
      }

      let wasRunning = status == .running
      if wasRunning {
        try awaitBlocking {
          try await manager.stopAndUninstall()
          try await waitUntilStopped(manager)
        }
      }

      let transaction = try stageAndSwitch(
        from: bundled, to: destination, version: packageVersion)
      do {
        try awaitBlocking {
          try await manager.installAndStart()
        }
        transaction.commit()
      } catch {
        transaction.rollback()
        if wasRunning {
          try? awaitBlocking {
            try await manager.installAndStart()
          }
        }
        throw error
      }
      return .installed
    } catch {
      return .failed("\(error)")
    }
  }

  static func bundledHelperDirectory(in bundle: Bundle) -> URL? {
    guard let resources = bundle.resourceURL else { return nil }
    let bundled = resources.appendingPathComponent("bin", isDirectory: true)
    guard helpers.allSatisfy({
      FileManager.default.isExecutableFile(atPath: bundled.appendingPathComponent($0).path)
    }) else {
      return nil
    }
    guard !bundledRuntimeFiles(in: bundled).isEmpty else { return nil }
    return bundled
  }

  static func bundledRuntimeFiles(in directory: URL) -> [URL] {
    (try? FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    ))?
      .filter { $0.pathExtension.caseInsensitiveCompare("dll") == .orderedSame }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
      ?? []
  }

  static func helpersInstalled(in directory: URL) -> Bool {
    helpers.allSatisfy {
      FileManager.default.isExecutableFile(
        atPath: directory.appendingPathComponent($0).path)
    } && !bundledRuntimeFiles(in: directory).isEmpty
  }

  static func packageVersion(for directory: URL) throws -> String {
    if let marker = try? String(
      contentsOf: directory.appendingPathComponent(versionFile), encoding: .utf8
    ) {
      let value = marker.trimmingCharacters(in: .whitespacesAndNewlines)
      if !value.isEmpty { return value }
    }
    let files = helpers.map { directory.appendingPathComponent($0) }
      + bundledRuntimeFiles(in: directory)
    var material = Data()
    for file in files {
      material.append(contentsOf: Data(file.lastPathComponent.utf8))
      material.append(0)
      material.append(try Data(contentsOf: file))
      material.append(0)
    }
    return GraphcodeSHA256.hex(material)
  }

  static func installedPackageVersion(in directory: URL) -> String? {
    try? String(
      contentsOf: directory.appendingPathComponent(versionFile), encoding: .utf8
    ).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Stages and switches a complete versioned package. The returned transaction
  /// keeps the old package until the new daemon has started successfully.
  static func installBundledFiles(
    from bundled: URL,
    to destination: URL,
    failAfterCopy: Int? = nil
  ) throws {
    let version = try packageVersion(for: bundled)
    let transaction = try stageAndSwitch(
      from: bundled,
      to: destination,
      version: version,
      failAfterCopy: failAfterCopy)
    transaction.commit()
  }

  private static func stageAndSwitch(
    from bundled: URL,
    to destination: URL,
    version: String,
    failAfterCopy: Int? = nil
  ) throws -> PackageSwitch {
    let fileManager = FileManager.default
    let runtimeFiles = bundledRuntimeFiles(in: bundled)
    let files = helpers.map { bundled.appendingPathComponent($0) } + runtimeFiles
    guard !runtimeFiles.isEmpty else {
      throw StartupManagerError.missingRuntimeFiles
    }
    let parent = destination.deletingLastPathComponent()
    try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
    let packageRoot = parent.appendingPathComponent(".graphcode-packages", isDirectory: true)
    try fileManager.createDirectory(at: packageRoot, withIntermediateDirectories: true)
    let staging = packageRoot.appendingPathComponent(
      "\(version)-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
    defer {
      if fileManager.fileExists(atPath: staging.path) {
        try? fileManager.removeItem(at: staging)
      }
    }

    for source in files {
      let target = staging.appendingPathComponent(source.lastPathComponent)
      try fileManager.copyItem(at: source, to: target)
      if let failAfterCopy, files.firstIndex(of: source).map({ $0 + 1 }) == failAfterCopy {
        throw StartupManagerError.commandFailed(
          command: "copy package", output: "injected mid-package failure")
      }
    }
    try Data(version.utf8).write(
      to: staging.appendingPathComponent(versionFile), options: .atomic)

    let backup = parent.appendingPathComponent(
      ".graphcode-rollback-\(UUID().uuidString)", isDirectory: true)
    if fileManager.fileExists(atPath: destination.path) {
      try moveItem(destination, to: backup, replaceExisting: false)
    }
    do {
      try moveItem(staging, to: destination, replaceExisting: false)
    } catch {
      if fileManager.fileExists(atPath: backup.path) {
        try? moveItem(backup, to: destination, replaceExisting: false)
      }
      throw error
    }
    return PackageSwitch(destination: destination, backup: backup)
  }

  private static func moveItem(
    _ source: URL,
    to target: URL,
    replaceExisting: Bool
  ) throws {
    var sourcePath = Array(source.path.utf16)
    sourcePath.append(0)
    var targetPath = Array(target.path.utf16)
    targetPath.append(0)
    let succeeded = sourcePath.withUnsafeBufferPointer { source in
      targetPath.withUnsafeBufferPointer { target in
        MoveFileExW(
          source.baseAddress,
          target.baseAddress,
          DWORD(
            (replaceExisting ? MOVEFILE_REPLACE_EXISTING : 0)
              | MOVEFILE_WRITE_THROUGH))
      }
    }

    guard succeeded else {
      throw WindowsPipeError.win32(operation: "MoveFileExW", code: GetLastError())
    }
  }

  private struct PackageSwitch {
    let destination: URL
    let backup: URL

    func commit() {
      try? FileManager.default.removeItem(at: backup)
    }

    func rollback() {
      try? FileManager.default.removeItem(at: destination)
      if FileManager.default.fileExists(atPath: backup.path) {
        try? DaemonBootstrap.moveItem(backup, to: destination, replaceExisting: false)
      }
    }
  }

  private static func waitUntilStopped(_ manager: WindowsStartupManager) async throws {
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
      if try await manager.status() != .running {
        return
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    throw StartupManagerError.commandFailed(
      command: "schtasks /End", output: "graphcoded did not stop before replacement")
  }

  private static func awaitBlocking<Result>(
    _ operation: @escaping () async throws -> Result
  ) throws -> Result {
    let semaphore = DispatchSemaphore(value: 0)
    let box = BlockingResult<Result>()
    Task {
      do {
        box.store(.success(try await operation()))
      } catch {
        box.store(.failure(error))
      }
      semaphore.signal()
    }
    semaphore.wait()
    return try box.take()
  }

  private final class BlockingResult<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<Value, Error>?

    func store(_ value: Result<Value, Error>) {
      lock.lock()
      self.value = value
      lock.unlock()
    }

    func take() throws -> Value {
      lock.lock()
      defer { lock.unlock() }
      guard let value else { fatalError("blocking result was not set") }
      return try value.get()
    }
  }
}

#endif
