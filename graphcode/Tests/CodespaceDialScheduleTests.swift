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

    #expect(await !breaker.permits(codespace, now: down.addingTimeInterval(539)))
    #expect(await breaker.permits(codespace, now: down.addingTimeInterval(540)))
    // One dial per interval for the whole codespace, not one per reader or loop.
    #expect(await !breaker.permits(codespace, now: down.addingTimeInterval(540)))
    #expect(await !breaker.permits(codespace, now: down.addingTimeInterval(839)))
    #expect(await breaker.permits(codespace, now: down.addingTimeInterval(840)))
    // A failed slow dial leaves the outage clock where it was.
    await breaker.record(codespace, reached: false, now: down.addingTimeInterval(845))
    #expect(await !breaker.permits(codespace, now: down.addingTimeInterval(900)))
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
    #expect(await !breaker.permits(codespace, now: down.addingTimeInterval(300)))

    try FileManager.default.setAttributes(
      [.modificationDate: down.addingTimeInterval(299)], ofItemAtPath: marker.path)
    #expect(await breaker.permits(codespace, now: down.addingTimeInterval(300)))
    // Resumed, not a one-off: the next read goes through too.
    #expect(await breaker.permits(codespace, now: down.addingTimeInterval(301)))
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
        prepare: "false", forward: "true", schedule: tiny, maxWait: 1))

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
