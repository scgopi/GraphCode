import Foundation
import XCTest

@testable import GraphcodeKit

/// `zmx ls` rows that say "I could not get an answer out of this session" are not a session
/// that is gone. These pin the classification, the decisions built on it, and the shell
/// scripts that launch (run under Git's POSIX shell here; the macOS twin runs them under
/// `/bin/sh`).
final class ZmxUnknownLivenessTests: XCTestCase {
  private static let name = "graphcode-5E11BA5E-0001-4000-8000-000000000001"
  private static let other = "graphcode-5E11BA5E-0002-4000-8000-000000000002"

  private static func row(_ name: String, _ fields: String = "") -> String {
    "name=\(name)\tpid=1\tclients=0\tcreated=1\(fields)\n"
  }

  private static func error(_ name: String, _ error: String, status: String = "unreachable")
    -> String
  {
    "  name=\(name)\terr=\(error)\tstatus=\(status)\n"
  }

  // MARK: - Classification

  func testOnlyAConnectionRefusedRowIsAbsentAndAnyOtherErrorIsUnknown() {
    func state(_ output: String) -> ZmxSessionLauncher.SessionTaskState {
      ZmxSessionLauncher.parseSessionTaskState(lsOutput: output, sessionName: Self.name)
    }
    XCTAssertEqual(state(Self.error(Self.name, "ConnectionRefused")), .absent)
    XCTAssertEqual(
      state(Self.error(Self.name, "ConnectionRefused", status: "cleaning up")), .absent)
    XCTAssertEqual(state(Self.error(Self.name, "Timeout")), .unknown)
    XCTAssertEqual(state(Self.error(Self.name, "Unexpected")), .unknown)
    XCTAssertEqual(state(Self.error(Self.name, "InfoSizeMismatch")), .unknown)
    XCTAssertEqual(state(Self.error(Self.name, "ConnectionRefusedAgain")), .unknown)
    XCTAssertEqual(state(Self.row(Self.name)), .alive)
    XCTAssertEqual(state(""), .absent)
    // Another session's error row says nothing about this one.
    XCTAssertEqual(state(Self.error(Self.other, "Timeout")), .absent)
    XCTAssertEqual(state(Self.error(Self.other, "Timeout") + Self.row(Self.name)), .alive)
    // A command line that merely contains `err=` is not an error row.
    XCTAssertEqual(state(Self.row(Self.name, "\tcmd=echo err=Timeout")), .alive)
  }

  func testRowsForOneSessionAggregateConservativelyInAnyOrder() {
    let refused = Self.error(Self.name, "ConnectionRefused")
    let timeout = Self.error(Self.name, "Timeout")
    let live = Self.row(Self.name)
    let ended = Self.row(Self.name, "\tended=5\texit_code=0")
    func state(_ output: String) -> ZmxSessionLauncher.SessionTaskState {
      ZmxSessionLauncher.parseSessionTaskState(lsOutput: output, sessionName: Self.name)
    }
    XCTAssertEqual(state(refused + live), .alive)
    XCTAssertEqual(state(live + refused), .alive)
    XCTAssertEqual(state(timeout + live), .unknown)
    XCTAssertEqual(state(live + timeout), .unknown)
    XCTAssertEqual(state(timeout + refused), .unknown)
    XCTAssertEqual(state(refused + timeout), .unknown)
    XCTAssertEqual(state(refused + refused), .absent)
    XCTAssertEqual(state(refused + ended), .exited(exitCode: 0))
    XCTAssertEqual(state(ended + refused), .exited(exitCode: 0))
  }

  func testLivenessMapsTheFourStatesAndAFailedListingIsUnknown() {
    func liveness(_ status: Int32?, _ output: String) -> SessionLiveness {
      ZmxSessionLauncher.sessionLiveness(
        lsStatus: status, lsOutput: output, sessionName: Self.name)
    }
    XCTAssertEqual(liveness(0, Self.row(Self.name)), .live)
    XCTAssertEqual(liveness(0, ""), .absent)
    XCTAssertEqual(liveness(0, Self.row(Self.name, "\tended=5")), .absent)
    XCTAssertEqual(liveness(0, Self.error(Self.name, "ConnectionRefused")), .absent)
    XCTAssertEqual(liveness(0, Self.error(Self.name, "Timeout")), .unknown)
    XCTAssertEqual(liveness(1, ""), .unknown)
    XCTAssertEqual(liveness(nil, ""), .unknown)
  }

  func testEveryDecisionRefusesToActOnUnknown() {
    typealias Launcher = ZmxSessionLauncher
    XCTAssertEqual(Launcher.startGate(for: .alive), .attach)
    XCTAssertEqual(Launcher.startGate(for: .absent), .launch)
    XCTAssertEqual(Launcher.startGate(for: .exited(exitCode: 1)), .launch)
    XCTAssertEqual(Launcher.startGate(for: .unknown), .refuse)
    XCTAssertEqual(Launcher.terminateGate(for: .alive), .kill)
    XCTAssertEqual(Launcher.terminateGate(for: .absent), .alreadyGone)
    XCTAssertEqual(Launcher.terminateGate(for: .exited(exitCode: nil)), .alreadyGone)
    XCTAssertEqual(Launcher.terminateGate(for: .unknown), .refuse)
    XCTAssertFalse(Launcher.shouldLaunch(after: .unknown))
    XCTAssertFalse(Launcher.shouldLaunch(after: .alive))
    XCTAssertTrue(Launcher.shouldLaunch(after: .absent))
    XCTAssertTrue(Launcher.resumeDied(after: .absent))
    XCTAssertTrue(Launcher.resumeDied(after: .exited(exitCode: 1)))
    XCTAssertFalse(Launcher.resumeDied(after: .alive))
    XCTAssertFalse(Launcher.resumeDied(after: .unknown))
  }

  func testTheBoolStaysFalseForUnknownAndThreeWayAnswerSaysWhy() {
    // The Bool is "provably alive" and nothing else; the enum is what a launch/kill/resolve
    // decision reads. Unknown is `false` for the first and `.unknown` for the second.
    let timeout = Self.error(Self.name, "Timeout")
    XCTAssertEqual(
      ZmxSessionLauncher.sessionLiveness(lsStatus: 0, lsOutput: timeout, sessionName: Self.name),
      .unknown)
    XCTAssertNotEqual(
      ZmxSessionLauncher.sessionLiveness(lsStatus: 0, lsOutput: timeout, sessionName: Self.name),
      .live)
  }

  // MARK: - The check-or-run script, against a fake zmx

  private struct Fixture {
    let directory: URL
    var zmx: URL { directory.appendingPathComponent("zmx") }
    var calls: [String] {
      ((try? String(contentsOf: directory.appendingPathComponent("calls"), encoding: .utf8)) ?? "")
        .split(separator: "\n").map(String.init)
    }
    var dialLog: String {
      (try? String(
        contentsOf: directory.appendingPathComponent(".graphcode/dials.log"), encoding: .utf8))
        ?? ""
    }
  }

  private static let shells: [URL] = {
    #if os(Windows)
      let paths = [
        "C:\\Program Files\\Git\\usr\\bin\\sh.exe", "C:\\Program Files\\Git\\usr\\bin\\bash.exe",
      ]
    #else
      let paths = ["/bin/sh", "/bin/dash", "/bin/bash"]
    #endif
    return paths.filter { FileManager.default.isExecutableFile(atPath: $0) }
      .map { URL(fileURLWithPath: $0) }
  }()

  /// Every shell, plain and under `-e` (the remote login shell may be either): the scripts
  /// must not rely on `pipefail` or on `grep` finding a match.
  private static let variants: [(shell: URL, flags: [String])] = shells.flatMap {
    [($0, ["-c"]), ($0, ["-e", "-c"])]
  }

  private func fixture(listing: String?) throws -> Fixture {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("zmx-unknown-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let script = """
      #!/bin/sh
      d=$(dirname "$0")
      echo "$1" >> "$d/calls"
      case "$1" in
        ls) [ -f "$d/ls.fail" ] && exit 1; cat "$d/ls.out"; exit 0;;
        get) echo busy; exit 0;;
        *) exit 0;;
      esac

      """
    try script.write(
      to: directory.appendingPathComponent("zmx"), atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: directory.appendingPathComponent("zmx").path)
    // The remote ensure shells out to python3 for its delivery; a stub keeps the test about zmx.
    try "#!/bin/sh\nexit 0\n".write(
      to: directory.appendingPathComponent("python3"), atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: directory.appendingPathComponent("python3").path)
    if let listing {
      try listing.write(
        to: directory.appendingPathComponent("ls.out"), atomically: true, encoding: .utf8)
    } else {
      try "x".write(
        to: directory.appendingPathComponent("ls.fail"), atomically: true, encoding: .utf8)
    }
    return Fixture(directory: directory)
  }

  @discardableResult
  private func run(
    _ script: String, in fixture: Fixture, shell: URL? = nil, flags: [String] = ["-c"]
  ) throws -> String {
    guard let shell = shell ?? Self.shells.first else {
      throw XCTSkip("no POSIX shell at the expected path")
    }
    let process = Process()
    process.executableURL = shell
    #if os(Windows)
      // A 13 KB script with embedded quotes and newlines does not survive Windows command-line
      // quoting into the MSYS shell, so it runs from a file with the same shell flags.
      let file = fixture.directory.appendingPathComponent("script.sh")
      try script.write(to: file, atomically: true, encoding: .utf8)
      process.arguments =
        flags.filter { $0 != "-c" } + [file.path.replacingOccurrences(of: "\\", with: "/")]
    #else
      process.arguments = flags + [script]
    #endif
    var environment = ProcessInfo.processInfo.environment
    environment["HOME"] = fixture.directory.path
    #if os(Windows)
      environment["PATH"] = "\(fixture.directory.path);\(environment["PATH"] ?? "")"
    #else
      environment["PATH"] = "\(fixture.directory.path):\(environment["PATH"] ?? "")"
    #endif
    process.environment = environment
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
  }

  private func decideScript(agent: String?, stamp: String?, zmx: URL) -> String {
    // Forward slashes keep the path a plain word for either shell.
    let path = zmx.path.replacingOccurrences(of: "\\", with: "/")
    return ZmxSessionLauncher.launchDecisionScript(
      zmxPath: path, sessionName: Self.name, agent: agent,
      run: ZmxSessionLauncher.quotedCommand([path, "run", Self.name, "-d", "agent"]),
      logFragment: nil, stampCommand: stamp)
  }

  /// The calls the fake zmx saw, for each shell variant: all of them must agree.
  private func decide(
    listing: String?, agent: String? = nil, stamp: String? = nil
  ) throws -> [[String]] {
    try Self.variants.map { variant in
      let fixture = try fixture(listing: listing)
      try run(
        decideScript(agent: agent, stamp: stamp, zmx: fixture.zmx), in: fixture,
        shell: variant.shell, flags: variant.flags)
      return fixture.calls
    }
  }

  private func expectDecision(
    _ expected: [String], listing: String?, agent: String? = nil, stamp: String? = nil
  ) throws {
    let all = try decide(listing: listing, agent: agent, stamp: stamp)
    XCTAssertFalse(all.isEmpty)
    for calls in all { XCTAssertEqual(calls, expected, listing ?? "ls fails") }
  }

  func testATimeoutRowForTheTargetNeverInvokesRunAndListsExactlyOnce() throws {
    try expectDecision(["ls"], listing: Self.error(Self.name, "Timeout"))
    let fixture = try fixture(listing: Self.error(Self.name, "Timeout"))
    try run(decideScript(agent: nil, stamp: nil, zmx: fixture.zmx), in: fixture)
    XCTAssertTrue(fixture.dialLog.contains("\(Self.name) ensure skipped-unknown"))
  }

  func testAFailedListingNeverInvokesRunAndIsLogged() throws {
    try expectDecision(["ls"], listing: nil)
    let fixture = try fixture(listing: nil)
    try run(decideScript(agent: nil, stamp: nil, zmx: fixture.zmx), in: fixture)
    XCTAssertTrue(fixture.dialLog.contains("\(Self.name) ensure skipped-ls-failed"))
  }

  func testOnlyADefinitelyMissingOrEndedSessionIsLaunchedIntoEvenUnderErrexit() throws {
    // `grep` exits 1 on no match, which is exactly these listings: under `sh -e` an
    // unguarded extraction would abort before classifying.
    for listing in [
      Self.row(Self.other),
      Self.error(Self.name, "ConnectionRefused"),
      Self.row(Self.name, "\tended=5\texit_code=0"),
      "",
      Self.error(Self.other, "Timeout"),
    ] {
      try expectDecision(["ls", "run"], listing: listing)
    }
  }

  func testALiveSessionIsLeftAloneWhateverElseTheListingSays() throws {
    for listing in [
      Self.row(Self.name),
      Self.row(Self.name, "\tcmd=echo err=Timeout"),
      Self.error(Self.name, "ConnectionRefused") + Self.row(Self.name),
      Self.row(Self.name) + Self.error(Self.name, "ConnectionRefused"),
      Self.row(Self.name, "\tended=5\texit_code=0") + Self.row(Self.name),
    ] {
      try expectDecision(["ls"], listing: listing)
    }
  }

  func testUnknownDominatesALiveRowInEitherOrder() throws {
    let timeout = Self.error(Self.name, "Timeout")
    let live = Self.row(Self.name)
    try expectDecision(["ls"], listing: timeout + live)
    try expectDecision(["ls"], listing: live + timeout)
    try expectDecision(["ls"], listing: Self.error(Self.name, "ConnectionRefused") + timeout)
  }

  func testALiveSessionOfAnotherAgentIsNeverRunIntoWhateverItsLabel() throws {
    try expectDecision(["ls"], listing: Self.row(Self.name, "\tagent=codex"), agent: "codex")
    for calls in try decide(listing: Self.row(Self.name), agent: "codex", stamp: ":") {
      XCTAssertFalse(calls.contains("run"))
    }
    try expectDecision(
      ["ls"], listing: Self.row(Self.name, "\tagent=claudeCode"), agent: "codex")
    try expectDecision(["ls"], listing: Self.row(Self.name, "\tagent=codexFoo"), agent: "codex")
    try expectDecision(["ls"], listing: Self.error(Self.name, "Timeout"), agent: "codex")
    try expectDecision(["ls", "run"], listing: Self.row(Self.other), agent: "codex")
  }

  func testAMismatchedLabelIsLoggedAsASkip() throws {
    let fixture = try fixture(listing: Self.row(Self.name, "\tagent=claudeCode"))
    try run(decideScript(agent: "codex", stamp: nil, zmx: fixture.zmx), in: fixture)
    XCTAssertTrue(fixture.dialLog.contains("\(Self.name) ensure skipped-agent-mismatch"))
  }

  // MARK: - The remote ensure, executed against a fake zmx

  private func remoteCalls(
    listing: String?, backend: CLISessionBackendKind = .claudeCode,
    variant: (shell: URL, flags: [String])
  ) throws -> [String] {
    let fixture = try fixture(listing: listing)
    let node = LoopNode(
      id: UUID(uuidString: "5E11BA5E-0001-4000-8000-000000000001") ?? UUID(),
      title: "Fix", loopType: .goalBased, goal: GoalSpec(summary: "tests pass"),
      backend: backend)
    let location = RemoteProjectLocation(
      user: "dev", host: "build-box", port: 2222,
      remotePath: fixture.directory.path.replacingOccurrences(of: "\\", with: "/"))
    let built = try XCTUnwrap(
      ZmxSessionLauncher.remoteEnsureDialScript(
        forNode: node, at: location, settings: GraphcodeSettings()))
    try run(built.script, in: fixture, shell: variant.shell, flags: variant.flags)
    return fixture.calls
  }

  func testTheRemoteEnsureListsOnceAndNeverRunsForAnythingButADefinitelyAbsentSession() throws {
    let name = "graphcode-5E11BA5E-0001-4000-8000-000000000001"
    let runless: [(String?, CLISessionBackendKind)] = [
      (Self.error(name, "Timeout"), .claudeCode),
      (nil, .claudeCode),
      (Self.row(name), .claudeCode),
      (Self.row(name, "\tagent=claudeCode"), .codex),
      (Self.row(name, "\tagent=codexFoo"), .codex),
      (Self.error(name, "Timeout") + Self.row(name), .claudeCode),
    ]
    for variant in Self.variants {
      for (listing, backend) in runless {
        let calls = try remoteCalls(listing: listing, backend: backend, variant: variant)
        XCTAssertEqual(calls.filter { $0 == "ls" }.count, 1, "\(listing ?? "ls fails") \(calls)")
        XCTAssertFalse(calls.contains("run"), "\(listing ?? "ls fails") \(calls)")
      }
      for listing in ["", Self.error(name, "ConnectionRefused"), Self.row(name, "\tended=5")] {
        let calls = try remoteCalls(listing: listing, variant: variant)
        XCTAssertEqual(calls.filter { $0 == "ls" }.count, 1, "\(listing) \(calls)")
        XCTAssertEqual(calls.filter { $0 == "run" }.count, 1, "\(listing) \(calls)")
      }
    }
  }

  /// The delivery (a `python3` here) is the slow step in which a pane can create the session.
  /// The stub flips the listing to a live row when the delivery's installer is invoked, which is exactly a
  /// session appearing while the delivery runs: no `run` may follow, whatever the shell.
  func testASessionThatBecomesLiveDuringDeliveryIsNeverRunInto() throws {
    let name = "graphcode-5E11BA5E-0001-4000-8000-000000000001"
    for variant in Self.variants {
      let fixture = try fixture(listing: "")
      let flip = Self.row(name).replacingOccurrences(of: "\t", with: "\\t")
      try
        "#!/bin/sh\nd=$(dirname \"$0\")\ncase \"$*\" in *b64decode*) printf '\(flip)\\n' > \"$d/ls.out\";; esac\nexit 0\n"
        .write(
          to: fixture.directory.appendingPathComponent("python3"), atomically: true,
          encoding: .utf8)
      let node = LoopNode(
        id: UUID(uuidString: "5E11BA5E-0001-4000-8000-000000000001") ?? UUID(),
        title: "Fix", loopType: .goalBased, goal: GoalSpec(summary: "tests pass"))
      let location = RemoteProjectLocation(
        user: "dev", host: "build-box", port: 2222,
        remotePath: fixture.directory.path.replacingOccurrences(of: "\\", with: "/"))
      let built = try XCTUnwrap(
        ZmxSessionLauncher.remoteEnsureDialScript(
          forNode: node, at: location, settings: GraphcodeSettings()))
      try run(built.script, in: fixture, shell: variant.shell, flags: variant.flags)
      let listing = try String(
        contentsOf: fixture.directory.appendingPathComponent("ls.out"), encoding: .utf8)
      XCTAssertTrue(listing.contains(name), "the delivery never ran, so nothing was raced")
      XCTAssertFalse(fixture.calls.contains("run"), "\(fixture.calls)")
      XCTAssertEqual(fixture.calls.filter { $0 == "ls" }.count, 1, "\(fixture.calls)")
    }
  }

  func testTheRemoteEnsureStructureIsPinnedAsWell() throws {
    let node = LoopNode(
      title: "Fix", loopType: .goalBased, goal: GoalSpec(summary: "tests pass"))
    let location = RemoteProjectLocation(
      user: "dev", host: "build-box", port: 2222, remotePath: "/home/dev/widget")
    let command = try XCTUnwrap(
      ZmxSessionLauncher.remoteEnsureInvocation(forNode: node, at: location)?.last)
    let probe = try XCTUnwrap(command.range(of: "gc_lv=lsfail"))
    let launch = try XCTUnwrap(command.range(of: "'run'"))
    XCTAssertLessThan(probe.lowerBound, launch.lowerBound)
    let between = command[probe.lowerBound..<launch.lowerBound]
    XCTAssertFalse(between.contains("b64decode"))
    XCTAssertFalse(between.contains("python3"))
    XCTAssertFalse(between.contains("trustedFolders"))
    XCTAssertTrue(command.contains("skipped-unknown"))
    XCTAssertTrue(command.contains("skipped-ls-failed"))
    XCTAssertTrue(command.contains("skipped-agent-mismatch"))
  }

  // MARK: - The remote status probe

  func testTheRemoteStatusProbeNeverReadsUnknownAsAbsent() throws {
    let node = LoopNode(id: UUID(uuidString: "5E11BA5E-0001-4000-8000-000000000001")!, title: "x")
    // Under every shell variant, plain and `-e`: they must all agree.
    func probe(_ listing: String?) throws -> String {
      var answers: [String] = []
      for variant in Self.variants {
        let fixture = try fixture(listing: listing)
        let script = ZmxSessionLauncher.remoteStatusScript(forNode: node, label: "presence")
        answers.append(
          try run(script, in: fixture, shell: variant.shell, flags: variant.flags)
            .trimmingCharacters(in: .whitespacesAndNewlines))
      }
      XCTAssertEqual(Set(answers).count, 1, "\(answers)")
      return answers.first ?? ""
    }
    let id = node.id.uuidString
    let name = "graphcode-\(id)"
    let marker = ZmxSessionLauncher.remoteProbeMarker
    XCTAssertEqual(try probe(Self.row(name)), "\(marker) live busy")
    XCTAssertEqual(try probe(""), "\(marker) absent")
    XCTAssertEqual(try probe(Self.error(name, "ConnectionRefused")), "\(marker) absent")
    XCTAssertEqual(try probe(Self.row(name, "\tended=5\texit_code=3")), "\(marker) exited 3")
    XCTAssertEqual(try probe(Self.error(name, "Timeout")), "\(marker) unknown")
    XCTAssertEqual(try probe(nil), "\(marker) unknown")
    XCTAssertEqual(
      ZmxSessionLauncher.parseRemoteStatus(succeeded: true, output: "\(marker) unknown"),
      .unreachable)
  }
}
