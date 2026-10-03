import Foundation
import Testing

@testable import GraphcodeKit
@testable import graphcode

/// Selecting any loop of a codespace restarts its retry schedule (issue #480): a human
/// looking at the codespace is the one signal worth spending an API call on at once,
/// whether its dialers are holding or paused.
@Suite
struct CodespaceSelectionTests {
  private struct Pane {
    var process: Process
    var output: Pipe
    var stdin: Pipe
  }

  private let codespace = RemoteProjectLocation(
    host: "fluffy-space-waddle", remotePath: "/workspaces/widget", isCodespace: true)
  private let sshHost = RemoteProjectLocation(
    user: "dev", host: "build-box", remotePath: "/home/dev/widget")
  private let tiny = CodespaceDialSchedule(freeRetryWindow: 1, holdUntil: 3, pauseAfter: 4)

  private func scratch() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("codespace-select-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func lines(in file: URL) -> Int {
    ((try? String(contentsOf: file, encoding: .utf8)) ?? "")
      .split(whereSeparator: \.isNewline).count
  }

  // MARK: - The daemon and the app

  @Test
  func selectingALoopRestartsTheScheduleWhileHeld() async throws {
    let directory = try scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let breaker = CodespaceDialBreaker(markerDirectory: directory)
    let down = Date(timeIntervalSince1970: 1_000_000)
    let marker = CodespaceDialBreaker.reconnectMarker(for: codespace, in: directory)
    await breaker.record(codespace, reached: false, now: down)
    #expect(await !breaker.permits(codespace, now: down.addingTimeInterval(90)))

    FileManager.default.createFile(atPath: marker.path, contents: nil)
    try FileManager.default.setAttributes(
      [.modificationDate: down.addingTimeInterval(95)], ofItemAtPath: marker.path)

    #expect(await breaker.permits(codespace, now: down.addingTimeInterval(96)))
    // A new failure starts a fresh clock rather than resuming the old one.
    await breaker.record(codespace, reached: false, now: down.addingTimeInterval(97))
    #expect(await breaker.permits(codespace, now: down.addingTimeInterval(120)))
  }

  @Test
  func requestingAReconnectResumesTheDaemonToo() async throws {
    let directory = try scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let breaker = CodespaceDialBreaker(markerDirectory: directory.appendingPathComponent("dials"))
    await breaker.record(codespace, reached: false, now: Date().addingTimeInterval(-90))
    #expect(await !breaker.permits(codespace))

    CodespaceDialBreaker.requestReconnect(
      for: codespace, in: directory.appendingPathComponent("dials"))

    #expect(await breaker.permits(codespace))
  }

  @Test
  func onlyACodespaceLoopsSelectionAsksForAReconnect() {
    #expect(
      AppFeature.codespace(atProjectPath: codespace.projectPath)?.host == "fluffy-space-waddle")
    #expect(AppFeature.codespace(atProjectPath: sshHost.projectPath) == nil)
    #expect(AppFeature.codespace(atProjectPath: "/Users/dev/widget") == nil)
  }

  // MARK: - The terminal pane

  /// Starts a pane loop that keeps its stdin open, so only a dial, a selection or the test
  /// can move it on — on a pseudo-terminal via `script` when the pane must look like a
  /// real one.
  private func startPane(
    _ script: String, onATTY: Bool = false
  ) throws -> Pane {
    let process = Process()
    if onATTY {
      process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
      process.arguments = ["-q", "/dev/null", "/bin/sh", "-c", script]
    } else {
      process.executableURL = URL(fileURLWithPath: "/bin/sh")
      process.arguments = ["-c", script]
    }
    let stdin = Pipe()
    let stdout = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = FileHandle.nullDevice
    try process.run()
    return Pane(process: process, output: stdout, stdin: stdin)
  }

  private func waitFor(
    within limit: Duration = .seconds(15), _ condition: () -> Bool
  ) async -> Bool {
    let clock = ContinuousClock()
    let end = clock.now + limit
    while clock.now < end {
      if condition() { return true }
      try? await Task.sleep(for: .milliseconds(100))
    }
    return condition()
  }

  private func touch(_ file: URL) throws {
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: file.path, contents: nil)
    try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
  }

  @Test
  func aPaneWithoutAStampKeepsToTheSchedule() async throws {
    // No stamp can be made (mktemp and its fallback both fail), so a selection cannot be
    // told apart from the click that opened the pane: the pane must neither die nor take
    // every second as a request.
    let directory = try scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = directory.appendingPathComponent("dials")
    let marker = directory.appendingPathComponent("space.reconnect")
    FileManager.default.createFile(atPath: marker.path, contents: nil)
    let dial = "(echo dial >> \(RemoteProjectLocation.shellQuoted(log.path)); exit 1)"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [
      "-c",
      SSHReconnectLoop.codespaceScript(
        connect: dial, reconnect: dial, pauseMarker: marker.path, schedule: tiny),
    ]
    // macOS `mktemp` ignores an unusable TMPDIR, so a shim is what makes it fail.
    let shims = directory.appendingPathComponent("shims", isDirectory: true)
    try FileManager.default.createDirectory(at: shims, withIntermediateDirectories: true)
    let mktemp = shims.appendingPathComponent("mktemp")
    try "#!/bin/sh\nexit 1\n".write(to: mktemp, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mktemp.path)
    process.environment = [
      "PATH": "\(shims.path):/usr/bin:/bin", "TMPDIR": "/nonexistent/graphcode",
    ]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    defer { process.terminate() }

    #expect(await waitFor(within: .seconds(20)) { !process.isRunning })
    #expect(process.terminationStatus == 0)
    #expect((3...5).contains(lines(in: log)))
  }

  @Test
  func selectingTheLoopRedialsAHeldPaneAtOnce() async throws {
    let directory = try scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = directory.appendingPathComponent("dials")
    let marker = directory.appendingPathComponent("space.reconnect")
    let dial = "(echo dial >> \(RemoteProjectLocation.shellQuoted(log.path)); exit 1)"
    let held = CodespaceDialSchedule(freeRetryWindow: 1, holdUntil: 120, pauseAfter: 180)
    let pane = try startPane(
      SSHReconnectLoop.codespaceScript(
        connect: dial, reconnect: dial, pauseMarker: marker.path, schedule: held))
    defer { pane.process.terminate() }

    // Two dials inside the free minute, then a hold that would last until 120s.
    #expect(await waitFor { lines(in: log) >= 2 })
    try await Task.sleep(for: .seconds(2))
    let heldAt = lines(in: log)

    try touch(marker)

    #expect(await waitFor(within: .seconds(5)) { lines(in: log) > heldAt })
  }

  @Test
  func selectingTheLoopResumesAPausedPane() async throws {
    let directory = try scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = directory.appendingPathComponent("dials")
    let marker = directory.appendingPathComponent("space.reconnect")
    let dial = "(echo dial >> \(RemoteProjectLocation.shellQuoted(log.path)); exit 1)"
    let pane = try startPane(
      SSHReconnectLoop.codespaceScript(
        connect: dial, reconnect: dial, pauseMarker: marker.path, schedule: tiny),
      onATTY: true)
    defer { pane.process.terminate() }

    // Three or four dials before the pause at 4s, depending on where the first one
    // falls against `date +%s`'s whole seconds; paused, the pane dials no more.
    #expect(await waitFor { lines(in: log) >= 3 })
    var pausedAt = lines(in: log)
    let settleBy = ContinuousClock.now + .seconds(20)
    while ContinuousClock.now < settleBy {
      try await Task.sleep(for: .seconds(3))
      if lines(in: log) == pausedAt { break }
      pausedAt = lines(in: log)
    }
    #expect(lines(in: log) == pausedAt)
    #expect(pane.process.isRunning)

    try touch(marker)

    #expect(await waitFor(within: .seconds(5)) { lines(in: log) > pausedAt })
  }

  @Test
  func aPausedPaneRedialsOnItsOwnAfterTheSlowInterval() async throws {
    let directory = try scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = directory.appendingPathComponent("dials")
    let marker = directory.appendingPathComponent("space.reconnect")
    let dial = "(echo dial >> \(RemoteProjectLocation.shellQuoted(log.path)); exit 1)"
    let slow = CodespaceDialSchedule(
      freeRetryWindow: 1, holdUntil: 3, pauseAfter: 4, slowRetryInterval: 3)
    let pane = try startPane(
      SSHReconnectLoop.codespaceScript(
        connect: dial, reconnect: dial, pauseMarker: marker.path, schedule: slow),
      onATTY: true)
    defer { pane.process.terminate() }

    #expect(await waitFor { lines(in: log) >= 3 })
    try await Task.sleep(for: .seconds(5))
    let pausedAt = lines(in: log)

    // Nobody presses Enter or selects the loop.
    #expect(await waitFor(within: .seconds(10)) { lines(in: log) >= pausedAt + 2 })
    #expect(pane.process.isRunning)
    #expect(!FileManager.default.fileExists(atPath: marker.path))
  }
}
