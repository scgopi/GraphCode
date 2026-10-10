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
    XCTAssertEqual(state(Self.error(Self.name, "ConnectionRefused", status: "cleaning up")), .absent)
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

  private static func shell() -> URL? {
    #if os(Windows)
      let path = "C:\\Program Files\\Git\\usr\\bin\\sh.exe"
    #else
      let path = "/bin/sh"
    #endif
    return FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
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
    if let listing {
      try listing.write(
        to: directory.appendingPathComponent("ls.out"), atomically: true, encoding: .utf8)
    } else {
      try "x".write(
        to: directory.appendingPathComponent("ls.fail"), atomically: true, encoding: .utf8)
    }
    return Fixture(directory: directory)
  }

  private func run(_ script: String, in fixture: Fixture) throws {
    guard let shell = Self.shell() else { throw XCTSkip("no POSIX shell at the expected path") }
    let process = Process()
    process.executableURL = shell
    process.arguments = ["-c", script]
    var environment = ProcessInfo.processInfo.environment
    environment["HOME"] = fixture.directory.path
    process.environment = environment
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
  }

  private func decide(
    listing: String?, agent: String? = nil, stamp: String? = nil
  ) throws -> Fixture {
    let fixture = try fixture(listing: listing)
    // Forward slashes keep the path a plain word for either shell.
    let zmx = fixture.zmx.path.replacingOccurrences(of: "\\", with: "/")
    let script = ZmxSessionLauncher.launchDecisionScript(
      zmxPath: zmx, sessionName: Self.name, agent: agent,
      run: ZmxSessionLauncher.quotedCommand([zmx, "run", Self.name, "-d", "agent"]),
      logFragment: nil, stampCommand: stamp)
    try run(script, in: fixture)
    return fixture
  }

  func testATimeoutRowForTheTargetNeverInvokesRunAndListsExactlyOnce() throws {
    let fixture = try decide(listing: Self.error(Self.name, "Timeout"))
    XCTAssertEqual(fixture.calls, ["ls"])
    XCTAssertTrue(fixture.dialLog.contains("\(Self.name) ensure skipped-unknown"))
  }

  func testAFailedListingNeverInvokesRunAndIsLogged() throws {
    let fixture = try decide(listing: nil)
    XCTAssertEqual(fixture.calls, ["ls"])
    XCTAssertTrue(fixture.dialLog.contains("\(Self.name) ensure skipped-ls-failed"))
  }

  func testOnlyADefinitelyMissingOrEndedSessionIsLaunchedInto() throws {
    let missing = try decide(listing: Self.row(Self.other))
    XCTAssertEqual(missing.calls, ["ls", "run"])
    let refused = try decide(listing: Self.error(Self.name, "ConnectionRefused"))
    XCTAssertEqual(refused.calls, ["ls", "run"])
    let ended = try decide(listing: Self.row(Self.name, "\tended=5\texit_code=0"))
    XCTAssertEqual(ended.calls, ["ls", "run"])
    let empty = try decide(listing: "")
    XCTAssertEqual(empty.calls, ["ls", "run"])
    // Another session's timeout is not this one's.
    let elsewhere = try decide(listing: Self.error(Self.other, "Timeout"))
    XCTAssertEqual(elsewhere.calls, ["ls", "run"])
  }

  func testALiveSessionIsLeftAloneWhateverElseTheListingSays() throws {
    for listing in [
      Self.row(Self.name),
      Self.row(Self.name, "\tcmd=echo err=Timeout\tended-not"),
      Self.error(Self.name, "ConnectionRefused") + Self.row(Self.name),
      Self.row(Self.name) + Self.error(Self.name, "ConnectionRefused"),
      Self.row(Self.name, "\tended=5\texit_code=0") + Self.row(Self.name),
    ] {
      XCTAssertEqual(try decide(listing: listing).calls, ["ls"], listing)
    }
  }

  func testUnknownDominatesALiveRowInEitherOrder() throws {
    let timeout = Self.error(Self.name, "Timeout")
    let live = Self.row(Self.name)
    XCTAssertEqual(try decide(listing: timeout + live).calls, ["ls"])
    XCTAssertEqual(try decide(listing: live + timeout).calls, ["ls"])
    XCTAssertEqual(
      try decide(listing: Self.error(Self.name, "ConnectionRefused") + timeout).calls, ["ls"])
  }

  func testAnAgentLabelDecidesBetweenLeftAloneAdoptedAndRelaunched() throws {
    let zmxSet = "zmx set graphcode agent=codex"
    // Labelled for this agent: ready, untouched.
    XCTAssertEqual(
      try decide(
        listing: Self.row(Self.name, "\tagent=codex"), agent: "codex", stamp: zmxSet
      ).calls, ["ls"])
    // Alive but unlabelled: adopted (stamped), never relaunched. The stamp here is a shell
    // fragment, so the fake's call log would not see it; the run's absence is the point.
    XCTAssertFalse(
      try decide(listing: Self.row(Self.name), agent: "codex", stamp: ":").calls.contains("run"))
    // Labelled for another agent: a session running the wrong thing is relaunched.
    XCTAssertEqual(
      try decide(
        listing: Self.row(Self.name, "\tagent=claudeCode"), agent: "codex", stamp: nil
      ).calls, ["ls", "run"])
    // An agent label that merely starts with the name does not satisfy the gate.
    XCTAssertEqual(
      try decide(
        listing: Self.row(Self.name, "\tagent=codexFoo"), agent: "codex", stamp: nil
      ).calls, ["ls", "run"])
    // An unknown row blocks a Codex launch too.
    XCTAssertEqual(
      try decide(
        listing: Self.error(Self.name, "Timeout"), agent: "codex", stamp: nil
      ).calls, ["ls"])
  }

  func testTheRemoteEnsureClassifiesOnceAndLaunchesOnlyInTheAbsentArm() throws {
    let node = LoopNode(
      title: "Fix", loopType: .goalBased, goal: GoalSpec(summary: "tests pass"))
    let location = RemoteProjectLocation(
      user: "dev", host: "build-box", port: 2222, remotePath: "/home/dev/widget")
    let command = try XCTUnwrap(
      ZmxSessionLauncher.remoteEnsureInvocation(forNode: node, at: location)?.last)
    let probe = try XCTUnwrap(command.range(of: "gc_lv=lsfail"))
    let unknown = try XCTUnwrap(command.range(of: "skipped-unknown"))
    let launch = try XCTUnwrap(command.range(of: "'run'"))
    XCTAssertLessThan(probe.lowerBound, unknown.lowerBound)
    XCTAssertLessThan(unknown.lowerBound, launch.lowerBound)
    XCTAssertTrue(command.contains("skipped-ls-failed"))
  }

  // MARK: - The remote status probe

  func testTheRemoteStatusProbeNeverReadsUnknownAsAbsent() throws {
    let node = LoopNode(id: UUID(uuidString: "5E11BA5E-0001-4000-8000-000000000001")!, title: "x")
    func probe(_ listing: String?) throws -> String {
      let fixture = try fixture(listing: listing)
      let script = ZmxSessionLauncher.remoteStatusScript(forNode: node, label: "presence")
        .replacingOccurrences(of: "'zmx'", with: "'\(fixture.zmx.path.replacingOccurrences(of: "\\", with: "/"))'")
      guard let shell = Self.shell() else { throw XCTSkip("no POSIX shell at the expected path") }
      let process = Process()
      process.executableURL = shell
      process.arguments = ["-c", script]
      var environment = ProcessInfo.processInfo.environment
      environment["HOME"] = fixture.directory.path
      process.environment = environment
      let pipe = Pipe()
      process.standardOutput = pipe
      process.standardError = FileHandle.nullDevice
      try process.run()
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
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
