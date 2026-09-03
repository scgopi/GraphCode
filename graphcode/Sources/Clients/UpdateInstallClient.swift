import AppKit
import Dependencies
import Foundation
import GraphcodeKit

/// Downloads a release DMG, verifies what it carries, and swaps it into /Applications —
/// the drag the browser flow asks the human to do, done by the app on its own behalf.
/// Behind a client so the reducer's install flow is testable without a 40MB download,
/// a disk image, or a signature to verify.
struct UpdateInstallClient: Sendable {
  /// Downloads and installs, reporting download progress in 0...1. Returns once the new
  /// app is in place in /Applications; throws with a human-readable reason otherwise.
  var install:
    @Sendable (_ dmg: URL, _ progress: @escaping @Sendable (Double) -> Void) async throws
      -> Void
  /// Launches the installed app and exits this one.
  var relaunch: @Sendable () async -> Void
}

enum UpdateInstallFailure: Error, LocalizedError {
  case downloadFailed(status: Int)
  case mountFailed
  case nothingToInstall
  case signatureRejected
  case swapFailed(String)

  var errorDescription: String? {
    switch self {
    case .downloadFailed(let status):
      return "The download failed (status \(status))."
    case .mountFailed:
      return "The downloaded disk image couldn't be opened."
    case .nothingToInstall:
      return "The disk image doesn't contain an app."
    case .signatureRejected:
      return "The downloaded app isn't signed by GraphCode's developer."
    case .swapFailed(let reason):
      return "Couldn't replace the installed app: \(reason)"
    }
  }
}

extension UpdateInstallClient: DependencyKey {
  private static let installedApp = URL(fileURLWithPath: "/Applications/graphcode.app")

  static let liveValue = UpdateInstallClient(
    install: { dmg, progress in
      UpdateLog.record("install: \(dmg.lastPathComponent) -> \(installedApp.path)")
      let image = try await UpdateLog.step("download") {
        try await download(dmg, progress: progress)
      }
      defer { try? FileManager.default.removeItem(at: image) }
      let mountPoint = try await UpdateLog.step("attach") { try await attach(image) }
      do {
        let app = try await UpdateLog.step("locate app") { try appInside(mountPoint) }
        try await UpdateLog.step("verify signature") { try await verifySignature(of: app) }
        try await UpdateLog.step("swap into /Applications") {
          try await swapIntoApplications(app)
        }
      } catch {
        try? await UpdateLog.step("detach after failure") {
          try await run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"])
        }
        throw error
      }
      try? await UpdateLog.step("detach") {
        try await run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"])
      }
      UpdateLog.record("install: done")
    },
    relaunch: {
      // Started through LaunchServices rather than as a child of this process, and that
      // is the whole point. A GUI app launched by LaunchServices runs inside its own
      // RunningBoard job, and the processes it spawns belong to that job: when the app
      // goes, they are killed with it. The relaunch used to be a `/bin/sh` child holding
      // a `sleep` — exactly the thing that gets reaped — so the app quit and nothing came
      // back. (It is why Sparkle ships a separate helper *app* for this rather than
      // forking one.) LaunchServices spawns the successor under launchd instead, where
      // this process dying cannot reach it.
      //
      // `createsNewApplicationInstance` because `open` semantics apply here too: without
      // it a second workspace's window is merely activated and no new instance starts.
      let configuration = NSWorkspace.OpenConfiguration()
      configuration.createsNewApplicationInstance = true
      configuration.activates = true
      // The workspace this window belongs to, named rather than inherited — the default
      // one is the absence of the variable, so it is set only for a named workspace,
      // matching how `WorkspaceClient.open` starts one.
      let workspace = Workspace.current
      if !workspace.isDefault {
        configuration.environment = [SupportDirectory.environmentKey: workspace.url.path]
      }
      // Dropped before the successor starts, not on the way out: `claim` declines while
      // a live process still holds the file, so a successor that launches first would
      // never record itself and the workspace would read as free with a window open on
      // it. The `willTerminate` release still runs and is a no-op by then — it only
      // deletes a claim that still names this process.
      UpdateLog.record("relaunch: asking LaunchServices to open \(installedApp.path)")
      WorkspaceLock.release()
      let launched = await withCheckedContinuation { continuation in
        NSWorkspace.shared.openApplication(at: installedApp, configuration: configuration) {
          application, _ in
          continuation.resume(returning: application != nil)
        }
      }
      // Only once the successor is actually running: terminating first would race the
      // launch request against this process's own death.
      UpdateLog.record(
        launched
          ? "relaunch: LaunchServices started the successor"
          : "relaunch: LaunchServices REFUSED — falling back to the detached shell")
      if !launched {
        // Nothing to lose by trying the old way if LaunchServices refused outright.
        let reopen = Process()
        reopen.executableURL = URL(fileURLWithPath: "/bin/sh")
        reopen.arguments = [
          "-c",
          relaunchScript(
            pid: ProcessInfo.processInfo.processIdentifier, appPath: installedApp.path,
            workspace: workspace),
        ]
        try? reopen.run()
      }
      await MainActor.run { NSApplication.shared.terminate(nil) }
    })

  /// The fallback relauncher, for the case where LaunchServices refuses the open
  /// outright: a detached shell that brings the app back once this process is gone.
  ///
  /// Second choice, not first — a child process is exactly what a terminating app's
  /// RunningBoard job takes with it, which is the failure the LaunchServices path above
  /// exists to avoid. Kept because a refused open leaves nothing else to try.
  ///
  /// Both halves are there for a failure the obvious one-liner had. `open` without `-n`
  /// *activates* an instance that is already running rather than starting one (`man
  /// open`), and after an install there is very often one: a second workspace the human
  /// kept open with "Install Anyway", or this very process, still shutting down. Either
  /// swallowed the relaunch — whatever window was alive came forward, the default
  /// workspace never came back, and Relaunch Now read as a button that did nothing.
  ///
  /// And the wait was a flat `sleep 1`, which is a race against however long termination
  /// actually takes rather than a wait for it. Polling the pid ends the moment the
  /// process is gone and gives up after ten seconds, because a relaunch that never fires
  /// is worse than one that fires a beat early.
  ///
  /// The workspace is named explicitly rather than left to whatever the launched app
  /// inherits. Only the default workspace installs updates (`WorkspacesState
  /// .managesUpdates`), so today this always resolves to `env -u` — but a relaunch that
  /// silently depends on that gating is one edit away from reopening someone's named
  /// workspace as the default one, which reads as the update having thrown their
  /// projects away.
  static func relaunchScript(pid: Int32, appPath: String, workspace: Workspace) -> String {
    let key = SupportDirectory.environmentKey
    let named = workspace.isDefault ? "" : " --env \"\(key)=\(workspace.url.path)\""
    return """
      for _ in $(seq 1 100); do kill -0 \(pid) 2>/dev/null || break; sleep 0.1; done
      env -u \(key) /usr/bin/open -n\(named) "\(appPath)"
      """
  }

  /// Tests never touch the network or /Applications — override with a fixture.
  static let testValue = UpdateInstallClient(
    install: { _, _ in throw UpdateInstallFailure.mountFailed },
    relaunch: {})

  private static func download(
    _ url: URL, progress: @escaping @Sendable (Double) -> Void
  ) async throws -> URL {
    var request = URLRequest(url: url)
    request.timeoutInterval = 60
    let (bytes, response) = try await URLSession.shared.bytes(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard status == 200 else { throw UpdateInstallFailure.downloadFailed(status: status) }
    let expected = response.expectedContentLength

    let destination = FileManager.default.temporaryDirectory
      .appendingPathComponent("graphcode-update-\(UUID().uuidString).dmg")
    FileManager.default.createFile(atPath: destination.path, contents: nil)
    let file = try FileHandle(forWritingTo: destination)
    defer { try? file.close() }

    var buffer = Data()
    buffer.reserveCapacity(1 << 16)
    var written: Int64 = 0
    var reported = 0.0
    for try await byte in bytes {
      buffer.append(byte)
      if buffer.count == 1 << 16 {
        try file.write(contentsOf: buffer)
        written += Int64(buffer.count)
        buffer.removeAll(keepingCapacity: true)
        // Every percent, not every chunk — each report becomes an action in the store.
        let fraction = expected > 0 ? Double(written) / Double(expected) : 0
        if fraction - reported >= 0.01 {
          reported = fraction
          progress(fraction)
        }
      }
    }
    try file.write(contentsOf: buffer)
    progress(1)
    return destination
  }

  private static func attach(_ image: URL) async throws -> URL {
    let output = try await run(
      "/usr/bin/hdiutil", ["attach", image.path, "-nobrowse", "-readonly", "-plist"])
    guard
      let plist = try? PropertyListSerialization.propertyList(
        from: Data(output.utf8), format: nil) as? [String: Any],
      let entities = plist["system-entities"] as? [[String: Any]],
      let mountPoint = entities.compactMap({ $0["mount-point"] as? String }).first
    else { throw UpdateInstallFailure.mountFailed }
    return URL(fileURLWithPath: mountPoint)
  }

  private static func appInside(_ mountPoint: URL) throws -> URL {
    let contents = try? FileManager.default.contentsOfDirectory(
      at: mountPoint, includingPropertiesForKeys: nil)
    guard let app = contents?.first(where: { $0.pathExtension == "app" }) else {
      throw UpdateInstallFailure.nothingToInstall
    }
    return app
  }

  /// The image is notarized and downloaded over TLS, but the swap below runs with this
  /// user's rights — nothing goes into /Applications without carrying the same team's
  /// Developer ID signature as every release.
  private static func verifySignature(of app: URL) async throws {
    do {
      try await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
      let details = try await run("/usr/bin/codesign", ["-d", "--verbose=2", app.path])
      guard details.contains("TeamIdentifier=D3VJSNKD86") else {
        throw UpdateInstallFailure.signatureRejected
      }
    } catch {
      throw UpdateInstallFailure.signatureRejected
    }
  }

  /// Stage-then-swap, the way `DaemonBootstrap` installs helpers: the copy happens off
  /// to the side and the moment of truth is two renames, so a failure part-way leaves
  /// either the old app or the new one — never half of each. The running app's own
  /// bundle moving aside is fine; its files stay open.
  private static func swapIntoApplications(_ app: URL) async throws {
    let fm = FileManager.default
    let staged = URL(fileURLWithPath: "/Applications/.graphcode-update.app")
    let aside = URL(fileURLWithPath: "/Applications/.graphcode-previous.app")
    try? fm.removeItem(at: staged)
    try? fm.removeItem(at: aside)
    do {
      try await run("/usr/bin/ditto", [app.path, staged.path])
      if fm.fileExists(atPath: installedApp.path) {
        try fm.moveItem(at: installedApp, to: aside)
      }
      do {
        try fm.moveItem(at: staged, to: installedApp)
      } catch {
        try? fm.moveItem(at: aside, to: installedApp)
        throw error
      }
      try? fm.removeItem(at: aside)
    } catch {
      try? fm.removeItem(at: staged)
      throw UpdateInstallFailure.swapFailed(error.localizedDescription)
    }
  }

  /// Runs a tool and returns what it wrote.
  ///
  /// **The output goes to temporary files, not pipes, and that is the entire point.** The
  /// obvious shape — two `Pipe`s read to EOF from inside `terminationHandler` — hangs
  /// forever in two separate ways, and both are reachable from here:
  ///
  /// - A tool that writes more than the pipe buffer holds (64KB) blocks in `write` until
  ///   somebody reads. Nobody does, because the only reader runs on termination and the
  ///   tool cannot terminate while it is blocked writing.
  /// - `readDataToEndOfFile()` waits for every *write end* to close, which is not the
  ///   same as the tool exiting. `hdiutil attach` hands its descriptors to
  ///   `diskimages-helper`, which stays alive for as long as the image is attached — so
  ///   EOF never arrives even though `hdiutil` itself is long gone.
  ///
  /// Both present identically to the human: an install parked on "Installing…" with no
  /// error, no relaunch prompt and no way forward but a manual reinstall. A file has
  /// neither a capacity to fill nor an EOF to wait for, so neither failure exists.
  ///
  /// The timeout is the backstop for a tool that genuinely wedges. An error someone can
  /// read and report beats a dialog that sits there for the rest of the day.
  @discardableResult
  private static func run(
    _ tool: String, _ arguments: [String], timeout: TimeInterval = 600
  ) async throws -> String {
    let name = String(tool.split(separator: "/").last ?? "tool")
    let fileManager = FileManager.default
    let base = fileManager.temporaryDirectory
      .appendingPathComponent("graphcode-\(name)-\(UUID().uuidString)")
    let outURL = base.appendingPathExtension("out")
    let errURL = base.appendingPathExtension("err")
    fileManager.createFile(atPath: outURL.path, contents: nil)
    fileManager.createFile(atPath: errURL.path, contents: nil)
    defer {
      try? fileManager.removeItem(at: outURL)
      try? fileManager.removeItem(at: errURL)
    }

    nonisolated(unsafe) let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    process.standardOutput = try FileHandle(forWritingTo: outURL)
    process.standardError = try FileHandle(forWritingTo: errURL)

    let (exited, exitContinuation) = AsyncStream<Int32>.makeStream()
    // Installed before `run()` so the exit cannot be missed — the same rule `GitClient`
    // documents, for the same reason.
    process.terminationHandler = { finished in
      exitContinuation.yield(finished.terminationStatus)
      exitContinuation.finish()
    }
    UpdateLog.record("  run: \(name) \(arguments.joined(separator: " "))")
    try process.run()

    let watchdog = Task {
      try await Task.sleep(for: .seconds(timeout))
      UpdateLog.record("  run: \(name) exceeded \(Int(timeout))s — terminating")
      process.terminate()
    }
    defer { watchdog.cancel() }

    var status: Int32 = -1
    for await exitStatus in exited { status = exitStatus }

    let output = (try? Data(contentsOf: outURL)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    let errors = (try? Data(contentsOf: errURL)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    UpdateLog.record("  run: \(name) exited \(status)")
    guard status == 0 else {
      throw UpdateInstallFailure.swapFailed("\(name) failed: \(errors)")
    }
    return output + errors
  }
}

extension DependencyValues {
  var updateInstallClient: UpdateInstallClient {
    get { self[UpdateInstallClient.self] }
    set { self[UpdateInstallClient.self] = newValue }
  }
}
