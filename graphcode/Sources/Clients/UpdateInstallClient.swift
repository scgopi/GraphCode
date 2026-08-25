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
      let image = try await download(dmg, progress: progress)
      defer { try? FileManager.default.removeItem(at: image) }
      let mountPoint = try await attach(image)
      do {
        let app = try appInside(mountPoint)
        try await verifySignature(of: app)
        try await swapIntoApplications(app)
      } catch {
        try? await run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"])
        throw error
      }
      try? await run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"])
    },
    relaunch: {
      // A detached shell outlives this process and reopens the app *after* it exits, so
      // there is never a moment with two instances competing to be the zmx leader.
      let reopen = Process()
      reopen.executableURL = URL(fileURLWithPath: "/bin/sh")
      reopen.arguments = [
        "-c",
        relaunchScript(
          pid: ProcessInfo.processInfo.processIdentifier, appPath: installedApp.path,
          workspace: .current),
      ]
      try? reopen.run()
      await MainActor.run { NSApplication.shared.terminate(nil) }
    })

  /// The detached shell that brings the app back once this process is gone.
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

  @discardableResult
  private static func run(_ tool: String, _ arguments: [String]) async throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    return try await withCheckedThrowingContinuation { continuation in
      process.terminationHandler = { finished in
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errors = stderr.fileHandleForReading.readDataToEndOfFile()
        if finished.terminationStatus == 0 {
          continuation.resume(
            returning: String(bytes: output + errors, encoding: .utf8) ?? "")
        } else {
          let reason = String(bytes: errors, encoding: .utf8) ?? ""
          continuation.resume(
            throwing: UpdateInstallFailure.swapFailed(
              "\(tool.split(separator: "/").last ?? "tool") failed: \(reason)"))
        }
      }
      do {
        try process.run()
      } catch {
        continuation.resume(throwing: error)
      }
    }
  }
}

extension DependencyValues {
  var updateInstallClient: UpdateInstallClient {
    get { self[UpdateInstallClient.self] }
    set { self[UpdateInstallClient.self] = newValue }
  }
}
