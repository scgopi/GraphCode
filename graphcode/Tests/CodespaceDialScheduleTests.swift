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
/// owner stands by instead of deleting the first one's endpoint, that a serving forward
/// never tears down its own, and that no forwarder outlives its parent. The claim runs
/// its real python3 probe against a real listener.
extension CodespaceDialScheduleTests {
  /// Short on purpose: the socket path inside it must fit `sun_path`'s 104 bytes.
  private func shortHome() throws -> URL {
    let home = URL(fileURLWithPath: "/tmp/gcb-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(
      at: home.appendingPathComponent(".graphcode"), withIntermediateDirectories: true)
    return home
  }

  private func socketPath(in home: URL) -> String {
    home.appendingPathComponent(".graphcode/graphcoded.sock").path
  }

  /// Runs `RemoteSocketForwarder.claimCommand` against `home` and reports what it printed
  /// before the colon, and whether the socket survived.
  private func claim(in home: URL, path: String? = nil) async throws -> (
    verdict: String, socketKept: Bool
  ) {
    let (_, output) = try await runShell(
      "HOME=\(RemoteProjectLocation.shellQuoted(home.path));"
        + (path.map { " PATH=\(RemoteProjectLocation.shellQuoted($0));" } ?? "")
        + " \(RemoteSocketForwarder.claimCommand(probeTimeout: 1))")
    let verdict = String(output.prefix { $0 != ":" })
    return (verdict, FileManager.default.fileExists(atPath: socketPath(in: home)))
  }

  private func dialsLog(in home: URL) -> String {
    (try? String(
      contentsOf: home.appendingPathComponent(".graphcode/dials.log"), encoding: .utf8)) ?? ""
  }

  private func occurrences(of event: String, in log: String) -> Int {
    log.components(separatedBy: " forward \(event) ").count - 1
  }

  @Test
  func aClaimLeavesAnAnsweringSocketAlone() async throws {
    let home = try shortHome()
    let listener = try StandInListener(path: socketPath(in: home))
    defer { listener.stop() }

    let (verdict, kept) = try await claim(in: home)

    #expect(verdict == "live")
    #expect(kept)
  }

  @Test
  func aClaimTreatsADaemonTooBusyToAnswerAsLive() async throws {
    let home = try shortHome()
    let listener = try StandInListener(path: socketPath(in: home), delay: 3)
    defer { listener.stop() }

    let (verdict, kept) = try await claim(in: home)

    #expect(verdict == "live")
    #expect(kept)
  }

  @Test
  func aClaimClearsASocketNobodyListensOn() async throws {
    let home = try shortHome()
    _ = try StandInListener(path: socketPath(in: home), answers: false)

    let (verdict, kept) = try await claim(in: home)

    #expect(verdict == "free")
    #expect(!kept)
  }

  @Test
  func withoutPython3AClaimNeverRemovesASocket() async throws {
    let home = try shortHome()
    _ = try StandInListener(path: socketPath(in: home), answers: false)

    let (verdict, kept) = try await claim(in: home, path: "/bin")

    #expect(verdict == "live")
    #expect(kept)
  }

  @Test
  func aClaimWithNoSocketIsFree() async throws {
    let (verdict, _) = try await claim(in: try shortHome())
    #expect(verdict == "free")
  }

  @Test
  func aForwarderStandsByWhileAnotherOwnerServesAndSaysSoOnce() async throws {
    let home = try scratch()
    let forwarded = home.appendingPathComponent("forwarded")
    let script =
      "HOME=\(RemoteProjectLocation.shellQuoted(home.path)); "
      + RemoteSocketForwarder.sshForwardScript(
        claim: "printf 'live:/remote'", check: "printf ino:5",
        forward: "touch \(RemoteProjectLocation.shellQuoted(forwarded.path))",
        host: "build-box", recheck: 1)

    _ = try await runShell(script, limit: 6)

    #expect(!FileManager.default.fileExists(atPath: forwarded.path))
    let log = dialsLog(in: home)
    #expect(log.contains("bridge"))
    #expect(occurrences(of: "standby", in: log) == 1)
  }

  @Test
  func aServingForwardNeverTearsDownItsOwnEndpoint() async throws {
    let home = try scratch()
    let binds = home.appendingPathComponent("binds")
    let script =
      "HOME=\(RemoteProjectLocation.shellQuoted(home.path)); "
      + RemoteSocketForwarder.sshForwardScript(
        claim: "printf 'free:/remote'", check: "printf ino:5",
        forward: "echo bind >> \(RemoteProjectLocation.shellQuoted(binds.path)); sleep 30",
        host: "build-box", recheck: 1)

    _ = try await runShell(script, limit: 8)

    #expect(lines(in: binds) == 1)
    #expect(!dialsLog(in: home).contains("endpoint-"))
  }

  @Test
  func aServingForwardWhoseEndpointVanishedIsReplaced() async throws {
    let home = try scratch()
    let binds = home.appendingPathComponent("binds")
    let seen = RemoteProjectLocation.shellQuoted(home.appendingPathComponent("seen").path)
    let script =
      "HOME=\(RemoteProjectLocation.shellQuoted(home.path)); "
      + RemoteSocketForwarder.sshForwardScript(
        claim: "printf 'free:/remote'",
        check: "if [ -f \(seen) ]; then printf ino:; else touch \(seen); printf ino:5; fi",
        forward: "echo bind >> \(RemoteProjectLocation.shellQuoted(binds.path)); sleep 30",
        host: "build-box", recheck: 1)

    _ = try await runShell(script, limit: 16)

    // The forward process never exits on its own here; only the check finding the path
    // gone can have started the second one.
    #expect(lines(in: binds) >= 2)
    #expect(occurrences(of: "endpoint-lost", in: dialsLog(in: home)) == 1)
  }

  @Test
  func aServingForwardStepsAsideForAnotherOwnersSocket() async throws {
    let home = try scratch()
    let seen = RemoteProjectLocation.shellQuoted(home.appendingPathComponent("seen").path)
    let script =
      "HOME=\(RemoteProjectLocation.shellQuoted(home.path)); "
      + RemoteSocketForwarder.sshForwardScript(
        claim: "printf 'free:/remote'",
        check: "if [ -f \(seen) ]; then printf ino:6; else touch \(seen); printf ino:5; fi",
        forward: "sleep 30", host: "build-box", recheck: 1)

    _ = try await runShell(script, limit: 8)

    #expect(occurrences(of: "endpoint-replaced", in: dialsLog(in: home)) == 1)
  }

  @Test
  func aHostThatStaysDownIsLoggedOnce() async throws {
    let home = try scratch()
    let script =
      "HOME=\(RemoteProjectLocation.shellQuoted(home.path)); "
      + RemoteSocketForwarder.sshForwardScript(
        claim: "false", check: "true", forward: "true", host: "build-box")

    _ = try await runShell(script, limit: 14)

    let log = dialsLog(in: home)
    #expect(occurrences(of: "claim-failed", in: log) == 1)
    #expect(log.split(separator: "\n").count == 1)
  }

  @Test
  func aForwarderBlockedInADialStillDiesWithItsParent() async throws {
    let marker = "sleep 31\(Int.random(in: 100...999))"
    let inner = RemoteSocketForwarder.sshForwardScript(
      claim: marker, check: "true", forward: "true", host: "build-box")
    // The supervisor's parent is this short-lived shell, not the test runner.
    _ = try await runShell(
      "/bin/sh -c \(RemoteProjectLocation.shellQuoted(inner)) >/dev/null 2>&1 & sleep 1; exit 0")

    try await Task.sleep(for: .seconds(3))
    let (_, survivors) = try await runShell("pgrep -f '\(marker)' || true")
    #expect(survivors.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
  }

  @Test
  func terminatingAForwarderMidDialStopsTheDialToo() async throws {
    let marker = "sleep 32\(Int.random(in: 100...999))"
    let started = Date()

    let (status, _) = try await runShell(
      RemoteSocketForwarder.sshForwardScript(
        claim: marker, check: "true", forward: "true", host: "build-box"),
      limit: 2)

    #expect(status == 0)
    #expect(Date().timeIntervalSince(started) < 6)
    let (_, survivors) = try await runShell("pgrep -f '\(marker)' || true")
    #expect(survivors.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
  }
}

/// A unix listener standing in for sshd's end of a forward: it answers each framed
/// request after `delay`, or, with `answers: false`, is bound and closed at once —
/// the stale socket a crashed forward leaves behind.
private final class StandInListener: @unchecked Sendable {
  private let descriptor: Int32
  private let answers: Bool

  init(path: String, answers: Bool = true, delay: TimeInterval = 0) throws {
    descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    self.answers = answers
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
      raw.copyBytes(from: path.utf8.prefix(raw.count - 1))
    }
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bound == 0, listen(descriptor, 8) == 0 else {
      close(descriptor)
      throw POSIXError(.EADDRINUSE)
    }
    guard answers else {
      close(descriptor)
      return
    }
    let listening = descriptor
    Thread.detachNewThread {
      while true {
        let client = accept(listening, nil, nil)
        guard client >= 0 else { return }
        var noSignal: Int32 = 1
        setsockopt(
          client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var request = [UInt8](repeating: 0, count: 64)
        _ = read(client, &request, request.count)
        Thread.sleep(forTimeInterval: delay)
        let reply: [UInt8] = [0, 0, 0, 2, 0x7B, 0x7D]
        _ = write(client, reply, reply.count)
        close(client)
      }
    }
  }

  func stop() {
    if answers { close(descriptor) }
  }
}
