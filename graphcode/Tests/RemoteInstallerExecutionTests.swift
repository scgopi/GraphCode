import Foundation
import Testing

@testable import GraphcodeKit

/// The installer fragment `RemoteGraphAccess.installerScript` builds, **actually run**.
///
/// Every other test of it asserts on the script as text — that it mentions `python3`,
/// that its manifest decodes, that it is `|| true`d. None of that notices a program that
/// python refuses to parse, and for five days none of it did: a stray `')` closed `exec(`
/// twice, so the whole delivery raised `SyntaxError` before writing a byte, silently,
/// because the fragment ends in `|| true`. Remote hosts and Codespaces got no CLI shim,
/// no briefing, no wake digest and no prompt file for the whole of 0.1.73.
///
/// So these run the real thing against a scratch `HOME` and look at what landed. That is
/// the only assertion that could have caught it, and the only one that stays true when
/// someone edits the embedded python again.
@Suite
struct RemoteInstallerExecutionTests {
  /// The installer is python, and a machine without it can only skip — never silently
  /// pass, which is the failure mode this suite exists to end.
  static var hasPython3: Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["python3", "-c", ""]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return false }
    process.waitUntilExit()
    return process.terminationStatus == 0
  }

  /// Runs `script` under `/bin/sh` with `HOME` pointed at a scratch directory, so the
  /// `~/` paths the manifest uses expand somewhere disposable rather than over the
  /// developer's own `~/.graphcode`.
  private func run(_ script: String, home: URL) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", script]
    var environment = ProcessInfo.processInfo.environment
    environment["HOME"] = home.path
    process.environment = environment
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
  }

  private func scratchHome() throws -> URL {
    let home = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("graphcode-installer-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    return home
  }

  @Test(.enabled(if: hasPython3))
  func theInstallerActuallyWritesEveryFileItCarries() throws {
    let home = try scratchHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let shim = RemoteGraphAccess.cliInstallPath
    let briefing = RemoteGraphAccess.briefingPath(forProjectPath: "/home/dev/widget")
    let script = try #require(
      RemoteGraphAccess.installerScript(
        files: [shim: RemoteGraphAccess.cliShimSource, briefing: "briefing text"],
        receipt: (path: RemoteGraphAccess.shimStampPath, content: "stamp-v1"),
        neutered: false))

    #expect(try run(script, home: home) == 0)

    func landed(_ homeRelative: String) -> String? {
      let url = home.appendingPathComponent(String(homeRelative.dropFirst(2)))
      return try? String(contentsOf: url, encoding: .utf8)
    }
    #expect(landed(shim) == RemoteGraphAccess.cliShimSource)
    #expect(landed(briefing) == "briefing text")
    // The receipt is the delivery's proof, written only after every file above landed.
    #expect(landed(RemoteGraphAccess.shimStampPath) == "stamp-v1")
    // The shim is executed by name on the remote host, so the bit matters.
    let shimURL = home.appendingPathComponent(String(shim.dropFirst(2)))
    #expect(FileManager.default.isExecutableFile(atPath: shimURL.path))
  }

  @Test(.enabled(if: hasPython3))
  func aDeliveredShimIsAProgramPythonCanRun() throws {
    // The shim is delivered as source and then run as a command. A manifest that lands
    // it byte-perfect is still useless if the bytes do not parse.
    let home = try scratchHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let script = try #require(
      RemoteGraphAccess.installerScript(
        files: [RemoteGraphAccess.cliInstallPath: RemoteGraphAccess.cliShimSource],
        neutered: false))
    #expect(try run(script, home: home) == 0)

    let shim = home.appendingPathComponent(
      String(RemoteGraphAccess.cliInstallPath.dropFirst(2)))
    #expect(try run("python3 -m py_compile \(shim.path)", home: home) == 0)
  }

  @Test(.enabled(if: hasPython3))
  func aFailedDeliveryIsSilentOnlyWhenItIsNeutered() throws {
    // The two halves of the contract the prompt delivery depends on: neutered swallows a
    // failure, un-neutered reports it, so a caller can chain a launch behind it.
    let home = try scratchHome()
    defer { try? FileManager.default.removeItem(at: home) }
    // A path under a file rather than a directory: `makedirs` cannot create it.
    let blocker = home.appendingPathComponent("blocker")
    try "x".write(to: blocker, atomically: true, encoding: .utf8)
    let doomed = "~/blocker/nested/PROMPT.md"

    let neutered = try #require(RemoteGraphAccess.installerScript(files: [doomed: "goal"]))
    #expect(try run(neutered, home: home) == 0)

    let reporting = try #require(
      RemoteGraphAccess.installerScript(files: [doomed: "goal"], neutered: false))
    #expect(try run(reporting, home: home) != 0)
  }

  @Test(.enabled(if: hasPython3))
  func aFailedDeliveryLeavesItsReasonInTheHostsDialLog() throws {
    // Silence is what cost five days: the installer raised SyntaxError into /dev/null,
    // so neither machine held a word about why every remote host was empty. Non-fatal
    // is right; traceless is not.
    let home = try scratchHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let blocker = home.appendingPathComponent("blocker")
    try "x".write(to: blocker, atomically: true, encoding: .utf8)
    let script = try #require(
      RemoteGraphAccess.installerScript(files: ["~/blocker/nested/PROMPT.md": "goal"]))

    #expect(try run(script, home: home) == 0)

    let log = home.appendingPathComponent(".graphcode/dials.log")
    let entry = try #require(try? String(contentsOf: log, encoding: .utf8))
    #expect(entry.contains("delivery install failed"))
    // The python's own words, not just that something went wrong.
    #expect(entry.contains("NotADirectoryError") || entry.contains("Errno 20"))
    // One line per entry, or every reader that splits on newlines mis-parses the log.
    #expect(entry.split(separator: "\n").count == 1)
  }

  @Test(.enabled(if: hasPython3))
  func aLoggedFailureLeavesTheWholeLogValidUTF8() throws {
    // The detail is cut to a byte budget, and a byte cut lands mid-character sooner or
    // later. One orphan continuation byte is not a cosmetic blemish: it makes `grep` and
    // `sed` fail on the *entire* file under a UTF-8 locale, so a feature written to make
    // one failure legible would hide every dial on the host instead.
    let home = try scratchHome()
    defer { try? FileManager.default.removeItem(at: home) }
    // A path whose non-ASCII characters run right through the tail boundary.
    let deep = "~/" + String(repeating: "é", count: 400) + "/PROMPT.md"
    let script = try #require(RemoteGraphAccess.installerScript(files: [deep: "goal"]))
    // Something to lose: an ordinary dial entry written before the failure.
    _ = try run(
      DialLog.fragment(session: "graphcode-x", dial: "ensure", event: "fresh"), home: home)

    #expect(try run(script, home: home) == 0)

    let log = home.appendingPathComponent(".graphcode/dials.log")
    let bytes = try #require(try? Data(contentsOf: log))
    #expect(String(data: bytes, encoding: .utf8) != nil, "dial log is not valid UTF-8")
    // The earlier entry must still be findable by the tools anyone would reach for.
    #expect(try run("grep -q 'ensure fresh' \(log.path)", home: home) == 0)
  }

  @Test(.enabled(if: hasPython3))
  func aLoggedFailureLineFitsTheTrimBudgetOnDisk() throws {
    // Measured from the file, not recomputed. `DialLogBoundTests` checks the arithmetic,
    // and arithmetic is exactly how this went wrong: the first budget left out the
    // trailing newline, the test that was written to lock it left the newline out the
    // same way, and a 210-byte line passed a 209-byte bound. Whatever the emitted
    // fragment really writes has to fit, terminator and all.
    let home = try scratchHome()
    defer { try? FileManager.default.removeItem(at: home) }
    // A deep path, so the traceback is far longer than the budget and the cut is real.
    let deep = "~/blocker/" + String(repeating: "nested/", count: 40) + "PROMPT.md"
    let blocker = home.appendingPathComponent("blocker")
    try "x".write(to: blocker, atomically: true, encoding: .utf8)
    let script = try #require(RemoteGraphAccess.installerScript(files: [deep: "goal"]))

    #expect(try run(script, home: home) == 0)

    let log = home.appendingPathComponent(".graphcode/dials.log")
    let written = try #require(try? Data(contentsOf: log))
    #expect(!written.isEmpty)
    #expect(written.count <= DialLog.maxBytes / DialLog.keptLines, "line is \(written.count) bytes")
    // And `keptLines` of them really do fit under the cap the trim measures against.
    #expect(DialLog.keptLines * written.count <= DialLog.maxBytes)
  }

  @Test(.enabled(if: hasPython3))
  func aFailureWithNoStderrStillRecordsItsExitCode() throws {
    // A killed installer — an OOM on a small box against a 105 KB argv — exits non-zero
    // with nothing on stderr. The one datum always available must not be dropped.
    let home = try scratchHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let install = try #require(
      RemoteGraphAccess.installerScript(files: [RemoteGraphAccess.cliInstallPath: "shim"]))
    // Replace the python with a silent failure, keeping the reporting tail intact.
    let silent = install.replacingOccurrences(
      of: "gc_di_err=$(", with: "gc_di_err=$(sh -c 'exit 137' && ")

    #expect(try run(silent, home: home) == 0)

    let entry = try #require(
      try? String(
        contentsOf: home.appendingPathComponent(".graphcode/dials.log"), encoding: .utf8))
    #expect(entry.contains("delivery install failed rc=137"))
  }

  @Test(.enabled(if: hasPython3))
  func aSucceedingDeliveryWritesNoDialLogNoise() throws {
    // The sweep dials every host every minute. A line per healthy delivery would bury
    // the one that matters under the ones that don't.
    let home = try scratchHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let script = try #require(
      RemoteGraphAccess.installerScript(files: [RemoteGraphAccess.cliInstallPath: "shim"]))

    #expect(try run(script, home: home) == 0)
    #expect(
      !FileManager.default.fileExists(
        atPath: home.appendingPathComponent(".graphcode/dials.log").path))
  }
}
