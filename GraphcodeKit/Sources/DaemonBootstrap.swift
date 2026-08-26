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
/// ordinary launches cost one small file read — plus one `launchctl print`, because a
/// launch also has to answer the question no file on disk can: whether the daemon the
/// stamp vouches for is actually loaded.
public enum DaemonBootstrap {
  public enum Outcome: Equatable {
    /// Not a packaged build, so there was nothing to install.
    case notPackaged
    /// Already installed and current.
    case upToDate
    /// Installed and current on disk, but launchd had lost the agent; it was loaded again.
    case reloaded
    case installed
    case failed(String)
  }

  /// One agent per workspace, so that opening a second one installs a daemon of its own
  /// instead of rewriting the first's. The default workspace keeps the bare label it has
  /// always had — an existing install must not see its agent renamed.
  static var label: String { Workspace.current.daemonLabel }
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

  /// The bundle's helper stamp when it no longer matches the one this workspace
  /// installed from it — a bundle replaced underneath a running app, which is what a
  /// `brew upgrade`, a DMG dragged over /Applications, or an install whose relaunch was
  /// declined all leave behind. `nil` when they agree, or when there is nothing packaged
  /// to compare.
  ///
  /// Deliberately only the three `stat`s the stamp is made of: no launchctl probe, no
  /// copy, no daemon reload. This is asked every time a window comes forward, and none of
  /// `installIfNeeded`'s work is work to repeat on activation — nor would it be *correct*
  /// there. Installing the new helpers under an app whose own code was swapped on disk
  /// leaves a new daemon serving an old window, which is a worse pairing than the stale
  /// one it replaced. The answer belongs to the human as a relaunch prompt; the relaunch
  /// is what runs the bootstrap, on both halves at once.
  public static func changedBundleStamp() -> String? {
    guard let bundled = bundledHelperDirectory() else { return nil }
    let expected = stamp(forHelpersIn: bundled)
    guard !expected.isEmpty else { return nil }
    let installed = try? String(contentsOf: stampURL, encoding: .utf8)
    return expected == installed ? nil : expected
  }

  @discardableResult
  public static func installIfNeeded() -> Outcome {
    guard let bundled = bundledHelperDirectory() else { return .notPackaged }

    let expected = stamp(forHelpersIn: bundled)
    let current = try? String(contentsOf: stampURL, encoding: .utf8)
    if current == expected, helpersInstalled(), launchAgentIsCurrent() {
      // Everything a file can record is right. The one thing no file records is whether
      // launchd still has the agent, and it routinely does not: an agent loaded the
      // legacy way is not re-bootstrapped into the next login session, so a reboot or a
      // logout leaves a correct install with no daemon behind it and nothing to say so.
      if daemonIsLoaded() { return .upToDate }
      reloadDaemon()
      return .reloaded
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

  static var launchAgentURL: URL { launchAgentURL(forLabel: label) }

  static func launchAgentURL(forLabel label: String) -> URL {
    URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
      .appendingPathComponent("Library/LaunchAgents/\(label).plist")
  }

  /// Takes a workspace's daemon out of launchd and removes its agent — the first step of
  /// deleting a workspace, and the one that cannot be skipped: the agent is `KeepAlive`,
  /// so a daemon left loaded over a deleted directory is restarted by launchd and
  /// recreates it.
  ///
  /// Refuses the default workspace outright. There is no path through the UI that asks
  /// for this, and the cost of being wrong is an install whose daemon is gone.
  public static func removeLaunchAgent(for workspace: Workspace) {
    guard !workspace.isDefault else { return }
    let url = launchAgentURL(forLabel: workspace.daemonLabel)
    launchctl(["bootout", "\(domainTarget)/\(workspace.daemonLabel)"])
    // The legacy pair as well, for an agent loaded by a build old enough to have used it.
    launchctl(["unload", url.path])
    try? FileManager.default.removeItem(at: url)
  }

  /// Built here rather than shipped as a template file: the two paths it needs are already
  /// known at runtime, and a template would be one more thing to keep in sync.
  ///
  /// `workspace` decides both the label and whether the daemon is told where to look.
  /// launchd starts an agent with its own minimal environment, so a named workspace's
  /// daemon inherits nothing from the app that installed it and would compute
  /// `~/.graphcode` — serving the default workspace's graphs under the second
  /// workspace's label. The default workspace passes no `EnvironmentVariables` at all,
  /// which keeps its plist byte-for-byte what it has always been: anything else and
  /// `launchAgentIsCurrent` would report every existing install as stale and bounce a
  /// daemon that was running perfectly well.
  static func launchAgentPlist(
    daemonPath: String, supportDirectory: String, workspace: Workspace = .current
  ) -> [String: Any] {
    var plist: [String: Any] = [
      "Label": workspace.daemonLabel,
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
    if !workspace.isDefault {
      plist["EnvironmentVariables"] = [SupportDirectory.environmentKey: supportDirectory]
    }
    return plist
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

  static var domainTarget: String { "gui/\(getuid())" }
  static var serviceTarget: String { "\(domainTarget)/\(label)" }

  /// Whether launchd currently holds the agent in this login session.
  ///
  /// Asking the plist, the helpers or the stamp cannot answer this — all three describe
  /// the disk, and the disk stays perfectly correct while the daemon is gone. `print`
  /// exits non-zero with "Could not find service" when the label is absent from the
  /// domain, which is the only durable signal there is.
  static func daemonIsLoaded(probe: ([String]) -> Int32 = launchctlStatus) -> Bool {
    probe(["print", serviceTarget]) == 0
  }

  /// Bootout then bootstrap. The teardown is what makes an app update actually take:
  /// without it, launchd keeps running the daemon binary it already started, and the
  /// freshly installed one never gets used.
  ///
  /// `bootstrap`/`bootout` rather than `load`/`unload` because the legacy pair registers
  /// the agent only for the session it is run in — the reason a reboot could strand a
  /// healthy install without a daemon. The legacy pair stays as a fallback for the case
  /// where the modern one is refused.
  private static func reloadDaemon() {
    launchctl(["bootout", serviceTarget])
    if launchctlStatus(["bootstrap", domainTarget, launchAgentURL.path]) != 0 {
      launchctl(["unload", launchAgentURL.path])
      launchctl(["load", launchAgentURL.path])
    }
  }

  private static func launchctl(_ arguments: [String]) {
    _ = launchctlStatus(arguments)
  }

  static func launchctlStatus(_ arguments: [String]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return -1 }
    process.waitUntilExit()
    return process.terminationStatus
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
  private static let endpointGenerationFile = ".graphcode-endpoint-generation"
  private static let runtimeFilesFile = ".graphcode-runtime-files"

  public static func installIfNeeded() -> Outcome {
    guard let bundled = bundledHelperDirectory(in: .main) else {
      return .notPackaged
    }

    let destination = SupportDirectory.binDirectory
    do {
      guard !bundledRuntimeFiles(in: bundled).isEmpty else {
        throw StartupManagerError.missingRuntimeFiles
      }
      let manager = try WindowsStartupManager(
        daemonURL: destination.appendingPathComponent("graphcoded.exe"))
      let packageVersion = try packageVersion(for: bundled)
      let status = try awaitBlocking { try await manager.status() }
      let processRunning = manager.isDaemonProcessRunning()
      let launcherCurrent = manager.launcherIsCurrent()
      let currentEndpointGeneration = try? WindowsNamedPipeEndpoint.generation()
      let endpointGenerationCurrent = Self.endpointGenerationIsCurrent(
        current: currentEndpointGeneration,
        installed: installedEndpointGeneration(in: destination))
      let installedCurrent =
        installedPackageVersion(in: destination) == packageVersion
        && helpersInstalled(in: destination)
        && runtimeFilesMatch(
          in: destination,
          required: bundledRuntimeFiles(in: bundled))
      if installedCurrent, !processRunning {
        if status == .running {
          // A stale scheduler state must not suppress a restart.
          try prepareAndStart(manager, destination: destination)
          return .installed
        }
        if status == .stopped || status == .notInstalled {
          try prepareAndStart(manager, destination: destination)
          return .installed
        }
      }
      if installedCurrent, status == .running, processRunning, launcherCurrent,
        endpointGenerationCurrent
      {
        return .upToDate
      }

      let wasRunning = status == .running || processRunning
      if wasRunning {
        guard status != .notInstalled else {
          throw StartupManagerError.commandFailed(
            command: "graphcoded termination",
            output: "the daemon process is running without its task")
        }
        try awaitBlocking {
          try await manager.stop()
          try await manager.waitForDaemonExit()
          try await waitUntilEndpointUnavailable()
          try await manager.uninstall()
        }
      }

      let endpointGeneration = try WindowsNamedPipeEndpoint.generation()
      let transaction = try stageAndSwitch(
        from: bundled,
        to: destination,
        version: packageVersion,
        endpointGeneration: endpointGeneration)
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
    guard helpers.allSatisfy({
      FileManager.default.isReadableFile(
        atPath: directory.appendingPathComponent($0).path)
    }) else {
      return false
    }
    guard
      let manifest = try? String(
        contentsOf: directory.appendingPathComponent(runtimeFilesFile),
        encoding: .utf8)
    else {
      return false
    }
    let required = Set(
      manifest.split(whereSeparator: \.isNewline)
        .map { $0.lowercased() })
    let installed = Set(
      bundledRuntimeFiles(in: directory)
        .map { $0.lastPathComponent.lowercased() })
    guard !required.isEmpty, required == installed else {
      return false
    }
    return required.allSatisfy {
      FileManager.default.isReadableFile(
        atPath: directory.appendingPathComponent($0).path)
    }
  }

  static func runtimeFilesMatch(in directory: URL, required: [URL]) -> Bool {
    Set(bundledRuntimeFiles(in: directory).map { $0.lastPathComponent.lowercased() })
      == Set(required.map { $0.lastPathComponent.lowercased() })
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

  static func installedEndpointGeneration(in directory: URL) -> String? {
    try? String(
      contentsOf: directory.appendingPathComponent(endpointGenerationFile),
      encoding: .utf8
    ).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func endpointGenerationIsCurrent(current: String?, installed: String?) -> Bool {
    guard let current, let installed else { return false }
    return current == installed
  }

  private static func prepareAndStart(
    _ manager: WindowsStartupManager,
    destination: URL
  ) throws {
    let generation = try WindowsNamedPipeEndpoint.generation()
    try Data(generation.utf8).write(
      to: destination.appendingPathComponent(endpointGenerationFile),
      options: .atomic)
    try awaitBlocking {
      try await manager.installAndStart()
    }
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
    endpointGeneration: String? = nil,
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
    let runtimeManifest = runtimeFiles.map(\.lastPathComponent).joined(separator: "\n")
    try Data((runtimeManifest + "\n").utf8).write(
      to: staging.appendingPathComponent(runtimeFilesFile), options: .atomic)
    if let endpointGeneration {
      try Data(endpointGeneration.utf8).write(
        to: staging.appendingPathComponent(endpointGenerationFile), options: .atomic)
    }

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

  private static func waitUntilEndpointUnavailable() async throws {
    let endpoint = try WindowsNamedPipeEndpoint.name()
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
      do {
        let connection = try WindowsNamedPipeClient.connect(
          to: endpoint, timeoutMilliseconds: 100)
        try await connection.close()
      } catch WindowsPipeError.win32(_, let code)
        where code == UInt32(truncatingIfNeeded: ERROR_FILE_NOT_FOUND)
          || code == UInt32(truncatingIfNeeded: ERROR_PIPE_NOT_CONNECTED)
      {
        return
      } catch WindowsPipeError.connectionClosed {
        try await Task.sleep(for: .milliseconds(50))
        continue
      } catch WindowsPipeError.win32(_, let code)
        where code == UInt32(truncatingIfNeeded: ERROR_PIPE_BUSY)
          || code == UInt32(truncatingIfNeeded: ERROR_SEM_TIMEOUT)
      {
        try await Task.sleep(for: .milliseconds(50))
        continue
      } catch WindowsPipeError.rendezvousSecretInUse {
        try await Task.sleep(for: .milliseconds(50))
        continue
      }
      catch {
        throw error
      }
    }
    throw StartupManagerError.commandFailed(
      command: "named pipe termination", output: "the daemon endpoint is still available")
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
