import ComposableArchitecture
import Foundation
import Testing

@testable import GraphcodeKit

/// One outage schedule for every Codespace dialer (issue #480): retry freely for a
/// minute, hold until the third, retry until the fourth, then pause to a slow retry.
/// Every gh run spends the human's Codespaces rate limit, so a dialer that retried on
/// its own clock forever spent it during every outage.
///
/// The shell loops are run, not string-matched, with the schedule shrunk to seconds: the
/// timing is the behaviour.
@Suite
struct CodespaceDialScheduleTests {
  private let codespace = RemoteProjectLocation(
    host: "fluffy-space-waddle", remotePath: "/workspaces/widget", isCodespace: true)
  private let sshHost = RemoteProjectLocation(
    user: "dev", host: "build-box", remotePath: "/home/dev/widget")
  private let tiny = CodespaceDialSchedule(freeRetryWindow: 1, holdUntil: 3, pauseAfter: 4)

  private func scratch() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("codespace-dial-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func runShell(
    _ script: String, input: String = "", limit: TimeInterval = 30
  ) async throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", script]
    let stdin = Pipe()
    let stdout = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = FileHandle.nullDevice
    let (exited, continuation) = AsyncStream<Int32>.makeStream()
    process.terminationHandler = {
      continuation.yield($0.terminationStatus)
      continuation.finish()
    }
    try process.run()
    stdin.fileHandleForWriting.write(Data(input.utf8))
    try stdin.fileHandleForWriting.close()
    let watchdog = Task {
      try await Task.sleep(for: .seconds(limit))
      process.terminate()
    }
    var status: Int32 = -1
    for await code in exited { status = code }
    watchdog.cancel()
    let output =
      String(
        data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return (status, output)
  }

  private func lines(in file: URL) -> Int {
    ((try? String(contentsOf: file, encoding: .utf8)) ?? "")
      .split(whereSeparator: \.isNewline).count
  }

  // MARK: - The schedule

  @Test
  func theScheduleRetriesHoldsRetriesThenPauses() {
    let schedule = CodespaceDialSchedule.standard
    #expect(schedule.verdict(secondsDown: nil) == .dial)
    #expect(schedule.verdict(secondsDown: 0) == .dial)
    #expect(schedule.verdict(secondsDown: 59) == .dial)
    #expect(schedule.verdict(secondsDown: 60) == .hold)
    #expect(schedule.verdict(secondsDown: 179) == .hold)
    #expect(schedule.verdict(secondsDown: 180) == .dial)
    #expect(schedule.verdict(secondsDown: 239) == .dial)
    #expect(schedule.verdict(secondsDown: 240) == .paused)
    #expect(schedule.verdict(secondsDown: 86_400) == .paused)
    #expect(schedule.slowRetryInterval == 60)
  }

  // MARK: - The daemon's breaker

  @Test
  func aCodespaceThatStoppedAnsweringIsDialedOnlyOnSchedule() async throws {
    let breaker = CodespaceDialBreaker(markerDirectory: try scratch())
    let down = Date(timeIntervalSince1970: 1_000_000)

    await breaker.record(codespace, reached: false, now: down)

    #expect(await breaker.permits(codespace, now: down.addingTimeInterval(30)))
    #expect(await !breaker.permits(codespace, now: down.addingTimeInterval(90)))
    #expect(await breaker.permits(codespace, now: down.addingTimeInterval(200)))
    #expect(await !breaker.permits(codespace, now: down.addingTimeInterval(250)))
  }

  @Test
  func aPausedCodespaceIsStillDialedOncePerSlowInterval() async throws {
    // A codespace restarted from outside graphcode can take longer than the four minutes
    // before the pause; its loops have to come back without a human selecting one.
    let breaker = CodespaceDialBreaker(markerDirectory: try scratch())
    let down = Date(timeIntervalSince1970: 1_000_000)
    await breaker.record(codespace, reached: false, now: down)

    #expect(await !breaker.permits(codespace, now: down.addingTimeInterval(299)))
    #expect(await breaker.permits(codespace, now: down.addingTimeInterval(300)))
    // One dial per interval for the whole codespace, not one per reader or loop.
    #expect(await !breaker.permits(codespace, now: down.addingTimeInterval(300)))
    #expect(await !breaker.permits(codespace, now: down.addingTimeInterval(359)))
    #expect(await breaker.permits(codespace, now: down.addingTimeInterval(360)))
    // A failed slow dial leaves the outage clock where it was.
    await breaker.record(codespace, reached: false, now: down.addingTimeInterval(365))
    #expect(await !breaker.permits(codespace, now: down.addingTimeInterval(400)))
    #expect(await breaker.permits(codespace, now: down.addingTimeInterval(86_400)))
  }

  @Test
  func aCodespaceThatAnswersAfterAnOutageAsksForTheRebootProbe() async throws {
    let recovered = LockIsolated<[String]>([])
    let breaker = CodespaceDialBreaker(
      markerDirectory: try scratch(),
      onRecovered: { location in recovered.withValue { $0.append(location.host) } })
    let down = Date(timeIntervalSince1970: 1_000_000)

    await breaker.record(codespace, reached: true, now: down)
    #expect(recovered.value.isEmpty)

    await breaker.record(codespace, reached: false, now: down)
    await breaker.record(codespace, reached: true, now: down.addingTimeInterval(600))
    await breaker.record(codespace, reached: true, now: down.addingTimeInterval(601))

    #expect(recovered.value == [codespace.host])
    #expect(await breaker.permits(codespace, now: down.addingTimeInterval(602)))
  }

  @Test
  func laterFailuresDoNotRestartTheOutageClock() async throws {
    let breaker = CodespaceDialBreaker(markerDirectory: try scratch())
    let down = Date(timeIntervalSince1970: 1_000_000)

    await breaker.record(codespace, reached: false, now: down)
    await breaker.record(codespace, reached: false, now: down.addingTimeInterval(50))

    #expect(await !breaker.permits(codespace, now: down.addingTimeInterval(90)))
  }

  @Test
  func reachingTheCodespaceClearsTheOutage() async throws {
    let breaker = CodespaceDialBreaker(markerDirectory: try scratch())
    let down = Date(timeIntervalSince1970: 1_000_000)

    await breaker.record(codespace, reached: false, now: down)
    await breaker.record(codespace, reached: true, now: down.addingTimeInterval(30))

    #expect(await breaker.permits(codespace, now: down.addingTimeInterval(90)))
  }

  @Test
  func aHumansReconnectResumesAPausedCodespace() async throws {
    let directory = try scratch()
    let breaker = CodespaceDialBreaker(markerDirectory: directory)
    let down = Date(timeIntervalSince1970: 1_000_000)
    let marker = CodespaceDialBreaker.reconnectMarker(for: codespace, in: directory)
    await breaker.record(codespace, reached: false, now: down)

    // A marker from before the outage is not a request to end it.
    FileManager.default.createFile(atPath: marker.path, contents: nil)
    try FileManager.default.setAttributes(
      [.modificationDate: down.addingTimeInterval(-60)], ofItemAtPath: marker.path)
    #expect(await !breaker.permits(codespace, now: down.addingTimeInterval(250)))

    try FileManager.default.setAttributes(
      [.modificationDate: down.addingTimeInterval(249)], ofItemAtPath: marker.path)
    #expect(await breaker.permits(codespace, now: down.addingTimeInterval(250)))
    // Resumed, not a one-off: the next read goes through too.
    #expect(await breaker.permits(codespace, now: down.addingTimeInterval(251)))
  }

  @Test
  func plainSSHHostsAreNeverHeldBack() async throws {
    let breaker = CodespaceDialBreaker(markerDirectory: try scratch())
    let down = Date(timeIntervalSince1970: 1_000_000)

    await breaker.record(sshHost, reached: false, now: down)

    #expect(await breaker.permits(sshHost, now: down.addingTimeInterval(90)))
    #expect(await breaker.permits(sshHost, now: down.addingTimeInterval(86_400)))
  }

  @Test
  func aReadOfAPausedCodespaceIsNeverDialed() async throws {
    let directory = try scratch()
    let breaker = CodespaceDialBreaker(
      schedule: CodespaceDialSchedule(freeRetryWindow: 0, holdUntil: 0, pauseAfter: 0),
      markerDirectory: directory)
    let failing = await ZmxSessionLauncher.collectRemoteOutput(
      ["/bin/sh", "-c", "exit 1"], location: codespace, breaker: breaker)
    #expect(failing.succeeded == false)

    let dialed = directory.appendingPathComponent("dialed")
    let read = await ZmxSessionLauncher.collectRemoteOutput(
      ["/bin/sh", "-c", "touch \(RemoteProjectLocation.shellQuoted(dialed.path))"],
      location: codespace, breaker: breaker)

    #expect(read.succeeded == false)
    try await Task.sleep(for: .milliseconds(300))
    #expect(!FileManager.default.fileExists(atPath: dialed.path))
  }

  // MARK: - The terminal pane

  @Test
  func aPaneRetriesOnTheScheduleThenPausesForAHuman() async throws {
    let directory = try scratch()
    let log = directory.appendingPathComponent("dials")
    let marker = directory.appendingPathComponent("space.reconnect")
    let dial = "(echo dial >> \(RemoteProjectLocation.shellQuoted(log.path)); exit 1)"

    let (status, output) = try await runShell(
      SSHReconnectLoop.codespaceScript(
        connect: dial, reconnect: dial, pauseMarker: marker.path, schedule: tiny))

    // Nobody answered the pause (stdin closed), so the pane closes cleanly.
    #expect(status == 0)
    #expect(output.contains("Paused to save your Codespaces API quota"))
    // Dials at about 0s and 1s, none while held until 3s, one more before the pause at
    // 4s. The old loop redialed every 1-2s for the whole outage.
    #expect((3...5).contains(lines(in: log)))
    #expect(!FileManager.default.fileExists(atPath: marker.path))
  }

  @Test
  func pressingEnterAtThePauseRedialsAndTellsTheDaemon() async throws {
    let directory = try scratch()
    let log = directory.appendingPathComponent("dials")
    let marker = directory.appendingPathComponent("nested/space.reconnect")
    let dial = "(echo dial >> \(RemoteProjectLocation.shellQuoted(log.path)); exit 1)"

    let (status, output) = try await runShell(
      SSHReconnectLoop.codespaceScript(
        connect: dial, reconnect: dial, pauseMarker: marker.path, schedule: tiny),
      input: "\n")

    #expect(status == 0)
    #expect(output.components(separatedBy: "Paused to save").count - 1 == 2)
    #expect(FileManager.default.fileExists(atPath: marker.path))
    #expect(lines(in: log) >= 5)
  }

  @Test
  func aPaneStillClosesOnANonRetryableExit() async throws {
    let directory = try scratch()
    let (status, _) = try await runShell(
      SSHReconnectLoop.codespaceScript(
        connect: "(exit 7)", reconnect: "(exit 7)",
        pauseMarker: directory.appendingPathComponent("m").path, schedule: tiny))

    #expect(status == 7)
  }

  // MARK: - The socket forwarder

  @Test
  func aCodespaceForwarderGivesUpInsteadOfRedialingForever() async throws {
    let started = Date()

    let (status, _) = try await runShell(
      RemoteSocketForwarder.codespaceForwardScript(
        claim: "false", forward: "true", schedule: tiny, maxWait: 1))

    #expect(status == 0)
    #expect(Date().timeIntervalSince(started) < 15)
  }

  @Test
  func onlyACodespaceForwarderUsesTheSchedule() {
    let codespaceScript = RemoteSocketForwarder.forwardScript(
      for: codespace, localSocketPath: "/Users/u/.graphcode/graphcoded.sock")
    let sshScript = RemoteSocketForwarder.forwardScript(
      for: sshHost, localSocketPath: "/Users/u/.graphcode/graphcoded.sock")

    #expect(codespaceScript.contains("gc_down"))
    #expect(codespaceScript.contains("kill -0 $PPID"))
    #expect(!sshScript.contains("gc_down"))
  }
}

/// The app and the daemon each forward the same remote socket; these pin that a second
/// owner stands by instead of deleting the first one's endpoint, and that no forwarder
/// outlives its parent.
extension CodespaceDialScheduleTests {
  /// Runs `RemoteSocketForwarder.claimCommand` against a scratch home, with `python3`
  /// replaced by a stub that answers the liveness probe with `probeStatus`.
  private func claim(probeStatus: Int) async throws -> (output: String, socketKept: Bool) {
    let home = try scratch()
    let bin = home.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let stub = bin.appendingPathComponent("python3")
    try "#!/bin/sh\nexit \(probeStatus)\n".write(to: stub, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
    let socket = home.appendingPathComponent(".graphcode/graphcoded.sock")
    try FileManager.default.createDirectory(
      at: socket.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data().write(to: socket)
    let (_, output) = try await runShell(
      "HOME=\(RemoteProjectLocation.shellQuoted(home.path));"
        + " PATH=\(RemoteProjectLocation.shellQuoted(bin.path)):$PATH;"
        + " \(RemoteSocketForwarder.claimCommand)")
    return (output, FileManager.default.fileExists(atPath: socket.path))
  }

  @Test
  func aClaimLeavesAnAnsweringSocketAlone() async throws {
    let (output, kept) = try await claim(probeStatus: 0)
    #expect(output.hasPrefix("live:"))
    #expect(kept)
  }

  @Test
  func aClaimClearsASocketNobodyAnswers() async throws {
    let (output, kept) = try await claim(probeStatus: 1)
    #expect(output.hasPrefix("free:"))
    #expect(!kept)
  }

  @Test
  func aForwarderStandsByWhileAnotherOwnerServes() async throws {
    let home = try scratch()
    let forwarded = home.appendingPathComponent("forwarded")
    let script =
      "HOME=\(RemoteProjectLocation.shellQuoted(home.path)); "
      + RemoteSocketForwarder.sshForwardScript(
        claim: "printf 'live:/remote'",
        forward: "touch \(RemoteProjectLocation.shellQuoted(forwarded.path))",
        host: "build-box", recheck: 1)

    _ = try await runShell(script, limit: 3)

    #expect(!FileManager.default.fileExists(atPath: forwarded.path))
    let log = try String(
      contentsOf: home.appendingPathComponent(".graphcode/dials.log"), encoding: .utf8)
    #expect(log.contains("bridge"))
    #expect(log.contains("standby build-box"))
  }

  @Test
  func aServingForwardWhoseEndpointVanishedIsReplaced() async throws {
    let home = try scratch()
    let binds = home.appendingPathComponent("binds")
    let script =
      "HOME=\(RemoteProjectLocation.shellQuoted(home.path)); "
      + RemoteSocketForwarder.sshForwardScript(
        claim: "printf 'free:/remote'",
        forward: "echo bind >> \(RemoteProjectLocation.shellQuoted(binds.path)); sleep 30",
        host: "build-box", recheck: 1)

    _ = try await runShell(script, limit: 12)

    // The forward process never exits on its own here; only the recheck finding the
    // path unanswered (`free:`) can have started the second one.
    #expect(lines(in: binds) >= 2)
    let log = try String(
      contentsOf: home.appendingPathComponent(".graphcode/dials.log"), encoding: .utf8)
    #expect(log.contains("endpoint-lost build-box"))
  }

  @Test
  func aForwarderBlockedInADialStillDiesWithItsParent() async throws {
    let marker = "sleep 31\(Int.random(in: 100...999))"
    let inner = RemoteSocketForwarder.sshForwardScript(
      claim: marker, forward: "true", host: "build-box")
    // The supervisor's parent is this short-lived shell, not the test runner.
    _ = try await runShell(
      "/bin/sh -c \(RemoteProjectLocation.shellQuoted(inner)) >/dev/null 2>&1 & sleep 1; exit 0")

    try await Task.sleep(for: .seconds(3))
    let (_, survivors) = try await runShell("pgrep -f '\(marker)' || true")
    #expect(survivors.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
  }
}
