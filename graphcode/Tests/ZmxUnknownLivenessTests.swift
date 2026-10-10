import Foundation
import Testing

@testable import GraphcodeKit

/// `zmx ls` rows that say "I could not get an answer out of this session" are not a session
/// that is gone — and acting on one as if it were is how a second launch command gets typed
/// into a live agent. These pin the classification, the decisions built on it, and the shell
/// scripts that launch, run under `/bin/sh` against a fake `zmx`.
@Suite
struct ZmxUnknownLivenessTests {
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

  private func state(_ output: String) -> ZmxSessionLauncher.SessionTaskState {
    ZmxSessionLauncher.parseSessionTaskState(lsOutput: output, sessionName: Self.name)
  }

  // MARK: - Classification

  @Test
  func onlyAConnectionRefusedRowIsAbsentAndAnyOtherErrorIsUnknown() {
    #expect(state(Self.error(Self.name, "ConnectionRefused")) == .absent)
    #expect(state(Self.error(Self.name, "ConnectionRefused", status: "cleaning up")) == .absent)
    #expect(state(Self.error(Self.name, "Timeout")) == .unknown)
    #expect(state(Self.error(Self.name, "Unexpected")) == .unknown)
    #expect(state(Self.error(Self.name, "InfoSizeMismatch")) == .unknown)
    #expect(state(Self.error(Self.name, "ConnectionRefusedAgain")) == .unknown)
    #expect(state(Self.row(Self.name)) == .alive)
    #expect(state("") == .absent)
    // Another session's error row says nothing about this one.
    #expect(state(Self.error(Self.other, "Timeout")) == .absent)
    #expect(state(Self.error(Self.other, "Timeout") + Self.row(Self.name)) == .alive)
    // A command line that merely contains `err=` is not an error row.
    #expect(state(Self.row(Self.name, "\tcmd=echo err=Timeout")) == .alive)
  }

  @Test
  func rowsForOneSessionAggregateConservativelyInAnyOrder() {
    let refused = Self.error(Self.name, "ConnectionRefused")
    let timeout = Self.error(Self.name, "Timeout")
    let live = Self.row(Self.name)
    let ended = Self.row(Self.name, "\tended=5\texit_code=0")
    #expect(state(refused + live) == .alive)
    #expect(state(live + refused) == .alive)
    #expect(state(timeout + live) == .unknown)
    #expect(state(live + timeout) == .unknown)
    #expect(state(timeout + refused) == .unknown)
    #expect(state(refused + timeout) == .unknown)
    #expect(state(refused + refused) == .absent)
    #expect(state(refused + ended) == .exited(exitCode: 0))
    #expect(state(ended + refused) == .exited(exitCode: 0))
  }

  @Test
  func livenessMapsTheStatesAndAFailedListingIsUnknown() {
    func liveness(_ status: Int32?, _ output: String) -> SessionLiveness {
      ZmxSessionLauncher.sessionLiveness(
        lsStatus: status, lsOutput: output, sessionName: Self.name)
    }
    #expect(liveness(0, Self.row(Self.name)) == .live)
    #expect(liveness(0, "") == .absent)
    #expect(liveness(0, Self.row(Self.name, "\tended=5")) == .absent)
    #expect(liveness(0, Self.error(Self.name, "ConnectionRefused")) == .absent)
    #expect(liveness(0, Self.error(Self.name, "Timeout")) == .unknown)
    #expect(liveness(1, "") == .unknown)
    #expect(liveness(nil, "") == .unknown)
  }

  @Test
  func everyDecisionRefusesToActOnUnknown() {
    typealias Launcher = ZmxSessionLauncher
    #expect(Launcher.startGate(for: .alive) == .attach)
    #expect(Launcher.startGate(for: .absent) == .launch)
    #expect(Launcher.startGate(for: .exited(exitCode: 1)) == .launch)
    #expect(Launcher.startGate(for: .unknown) == .refuse)
    #expect(Launcher.terminateGate(for: .alive) == .kill)
    #expect(Launcher.terminateGate(for: .absent) == .alreadyGone)
    #expect(Launcher.terminateGate(for: .exited(exitCode: nil)) == .alreadyGone)
    #expect(Launcher.terminateGate(for: .unknown) == .refuse)
    #expect(!Launcher.shouldLaunch(after: .unknown))
    #expect(!Launcher.shouldLaunch(after: .alive))
    #expect(Launcher.shouldLaunch(after: .absent))
    #expect(Launcher.resumeDied(after: .absent))
    #expect(Launcher.resumeDied(after: .exited(exitCode: 1)))
    #expect(!Launcher.resumeDied(after: .alive))
    #expect(!Launcher.resumeDied(after: .unknown))
  }

  // MARK: - The check-or-run script, against a fake zmx

  private final class Fixture {
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

    init(listing: String?) throws {
      directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("zmx-unknown-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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
      try script.write(to: zmx, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: zmx.path)
      if let listing {
        try listing.write(
          to: directory.appendingPathComponent("ls.out"), atomically: true, encoding: .utf8)
      } else {
        try "x".write(
          to: directory.appendingPathComponent("ls.fail"), atomically: true, encoding: .utf8)
      }
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    /// Runs `script` under `/bin/sh` with this directory as `$HOME`, returning its stdout.
    @discardableResult
    func run(_ script: String) throws -> String {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/sh")
      process.arguments = ["-c", script]
      process.environment = ["HOME": directory.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
      let pipe = Pipe()
      process.standardOutput = pipe
      process.standardError = FileHandle.nullDevice
      try process.run()
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      return String(decoding: data, as: UTF8.self)
    }
  }

  private func decide(
    listing: String?, agent: String? = nil, stamp: String? = nil
  ) throws -> Fixture {
    let fixture = try Fixture(listing: listing)
    let zmx = fixture.zmx.path
    let script = ZmxSessionLauncher.launchDecisionScript(
      zmxPath: zmx, sessionName: Self.name, agent: agent,
      run: ZmxSessionLauncher.quotedCommand([zmx, "run", Self.name, "-d", "agent"]),
      logFragment: nil, stampCommand: stamp)
    try fixture.run(script)
    return fixture
  }

  @Test
  func aTimeoutRowForTheTargetNeverInvokesRunAndListsExactlyOnce() throws {
    let fixture = try decide(listing: Self.error(Self.name, "Timeout"))
    #expect(fixture.calls == ["ls"])
    #expect(fixture.dialLog.contains("\(Self.name) ensure skipped-unknown"))
  }

  @Test
  func aFailedListingNeverInvokesRunAndIsLogged() throws {
    let fixture = try decide(listing: nil)
    #expect(fixture.calls == ["ls"])
    #expect(fixture.dialLog.contains("\(Self.name) ensure skipped-ls-failed"))
  }

  @Test
  func onlyADefinitelyMissingOrEndedSessionIsLaunchedInto() throws {
    for listing in [
      Self.row(Self.other),
      Self.error(Self.name, "ConnectionRefused"),
      Self.row(Self.name, "\tended=5\texit_code=0"),
      "",
      // Another session's timeout is not this one's.
      Self.error(Self.other, "Timeout"),
    ] {
      #expect(try decide(listing: listing).calls == ["ls", "run"], "\(listing)")
    }
  }

  @Test
  func aLiveSessionIsLeftAloneWhateverElseTheListingSays() throws {
    for listing in [
      Self.row(Self.name),
      Self.row(Self.name, "\tcmd=echo err=Timeout"),
      Self.error(Self.name, "ConnectionRefused") + Self.row(Self.name),
      Self.row(Self.name) + Self.error(Self.name, "ConnectionRefused"),
      Self.row(Self.name, "\tended=5\texit_code=0") + Self.row(Self.name),
    ] {
      #expect(try decide(listing: listing).calls == ["ls"], "\(listing)")
    }
  }

  @Test
  func unknownDominatesALiveRowInEitherOrder() throws {
    let timeout = Self.error(Self.name, "Timeout")
    let live = Self.row(Self.name)
    #expect(try decide(listing: timeout + live).calls == ["ls"])
    #expect(try decide(listing: live + timeout).calls == ["ls"])
    #expect(
      try decide(listing: Self.error(Self.name, "ConnectionRefused") + timeout).calls == ["ls"])
  }

  @Test
  func anAgentLabelDecidesBetweenLeftAloneAdoptedAndRelaunched() throws {
    // Labelled for this agent: ready, untouched.
    #expect(
      try decide(listing: Self.row(Self.name, "\tagent=codex"), agent: "codex", stamp: ":").calls
        == ["ls"])
    // Alive but unlabelled: adopted (stamped), never relaunched.
    #expect(
      try !decide(listing: Self.row(Self.name), agent: "codex", stamp: ":").calls.contains("run"))
    // Labelled for another agent, or for one whose name merely starts with it: relaunched.
    #expect(
      try decide(listing: Self.row(Self.name, "\tagent=claudeCode"), agent: "codex").calls
        == ["ls", "run"])
    #expect(
      try decide(listing: Self.row(Self.name, "\tagent=codexFoo"), agent: "codex").calls
        == ["ls", "run"])
    // An unknown row blocks a Codex launch too.
    #expect(
      try decide(listing: Self.error(Self.name, "Timeout"), agent: "codex").calls == ["ls"])
  }

  @Test
  func theRealLaunchFragmentsCarryTheSameProbeBeforeTheirRun() throws {
    // The remote ensure cannot be run without ssh, so it is pinned structurally: one
    // classification of `zmx ls` into `gc_lv`, and the launch only in the arm that a
    // definite absent reaches.
    let node = LoopNode(
      title: "Fix", loopType: .goalBased, goal: GoalSpec(summary: "tests pass"))
    let location = RemoteProjectLocation(
      user: "dev", host: "build-box", port: 2222, remotePath: "/home/dev/widget")
    let command = try #require(
      ZmxSessionLauncher.remoteEnsureInvocation(forNode: node, at: location)?.last)
    let probe = try #require(command.range(of: "gc_lv=lsfail"))
    let unknown = try #require(command.range(of: "skipped-unknown"))
    let launch = try #require(command.range(of: "'run'"))
    #expect(probe.lowerBound < unknown.lowerBound)
    #expect(unknown.lowerBound < launch.lowerBound)
    #expect(command.contains("skipped-ls-failed"))
  }

  // MARK: - The remote status probe

  @Test
  func theRemoteStatusProbeNeverReadsUnknownAsAbsent() throws {
    let id = try #require(UUID(uuidString: "5E11BA5E-0001-4000-8000-000000000001"))
    let node = LoopNode(id: id, title: "x")
    let name = "graphcode-\(node.id.uuidString)"
    func probe(_ listing: String?) throws -> String {
      let fixture = try Fixture(listing: listing)
      let script = ZmxSessionLauncher.remoteStatusScript(forNode: node, label: "presence")
        .replacingOccurrences(of: "'zmx'", with: "'\(fixture.zmx.path)'")
      return try fixture.run(script).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let marker = ZmxSessionLauncher.remoteProbeMarker
    #expect(try probe(Self.row(name)) == "\(marker) live busy")
    #expect(try probe("") == "\(marker) absent")
    #expect(try probe(Self.error(name, "ConnectionRefused")) == "\(marker) absent")
    #expect(try probe(Self.row(name, "\tended=5\texit_code=3")) == "\(marker) exited 3")
    #expect(try probe(Self.error(name, "Timeout")) == "\(marker) unknown")
    #expect(try probe(nil) == "\(marker) unknown")
    #expect(
      ZmxSessionLauncher.parseRemoteStatus(succeeded: true, output: "\(marker) unknown")
        == .unreachable)
  }
}
