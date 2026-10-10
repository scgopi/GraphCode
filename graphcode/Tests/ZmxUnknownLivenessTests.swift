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

    /// `listing` is what the fake `zmx ls` prints; `nil` makes it exit 1; `slow` makes it
    /// hang first.
    init(listing: String?, slow: Bool = false) throws {
      directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("zmx-unknown-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let script = """
        #!/bin/sh
        d=$(dirname "$0")
        echo "$1" >> "$d/calls"
        case "$1" in
          ls) [ -f "$d/ls.slow" ] && sleep 30; [ -f "$d/ls.fail" ] && exit 1
              cat "$d/ls.out"; exit 0;;
          get) echo busy; exit 0;;
          *) exit 0;;
        esac

        """
      try script.write(to: zmx, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: zmx.path)
      // The remote ensure shells out to python3 for its delivery; a stub keeps the test about
      // zmx.
      let python = directory.appendingPathComponent("python3")
      try "#!/bin/sh\nexit 0\n".write(to: python, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
      if let listing {
        try listing.write(
          to: directory.appendingPathComponent("ls.out"), atomically: true, encoding: .utf8)
      } else {
        try "x".write(
          to: directory.appendingPathComponent("ls.fail"), atomically: true, encoding: .utf8)
      }
      if slow {
        try "x".write(
          to: directory.appendingPathComponent("ls.slow"), atomically: true, encoding: .utf8)
      }
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    /// Runs `script` under `shell` with this directory as `$HOME` and first on `PATH` (the
    /// remote scripts name a bare `zmx`), returning its stdout.
    @discardableResult
    func run(_ script: String, shell: String = "/bin/sh", flags: [String] = ["-c"]) throws
      -> String
    {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: shell)
      process.arguments = flags + [script]
      process.environment = [
        "HOME": directory.path, "PATH": "\(directory.path):/usr/bin:/bin:/usr/sbin:/sbin",
      ]
      let pipe = Pipe()
      process.standardOutput = pipe
      process.standardError = FileHandle.nullDevice
      try process.run()
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      return String(decoding: data, as: UTF8.self)
    }
  }

  /// Every shell the scripts must survive: the login shell may be `sh -e`, dash or bash, and
  /// nothing here may rely on `pipefail`.
  private static let variants: [(shell: String, flags: [String])] = {
    ["/bin/sh", "/bin/dash", "/bin/bash"]
      .filter { FileManager.default.isExecutableFile(atPath: $0) }
      .flatMap { shell in [(shell, ["-c"]), (shell, ["-e", "-c"])] }
  }()

  private func decideScript(agent: String?, stamp: String?, zmx: String) -> String {
    ZmxSessionLauncher.launchDecisionScript(
      zmxPath: zmx, sessionName: Self.name, agent: agent,
      run: ZmxSessionLauncher.quotedCommand([zmx, "run", Self.name, "-d", "agent"]),
      logFragment: nil, stampCommand: stamp)
  }

  /// The calls the fake zmx saw, for each shell variant: all of them must agree.
  private func decide(
    listing: String?, agent: String? = nil, stamp: String? = nil
  ) throws -> [[String]] {
    try Self.variants.map { variant in
      let fixture = try Fixture(listing: listing)
      try fixture.run(
        decideScript(agent: agent, stamp: stamp, zmx: fixture.zmx.path),
        shell: variant.shell, flags: variant.flags)
      return fixture.calls
    }
  }

  private func expectDecision(
    _ expected: [String], listing: String?, agent: String? = nil, stamp: String? = nil
  ) throws {
    let all = try decide(listing: listing, agent: agent, stamp: stamp)
    #expect(!all.isEmpty)
    for calls in all { #expect(calls == expected, "\(listing ?? "ls fails")") }
  }

  @Test
  func aTimeoutRowForTheTargetNeverInvokesRunAndListsExactlyOnce() throws {
    try expectDecision(["ls"], listing: Self.error(Self.name, "Timeout"))
    let fixture = try Fixture(listing: Self.error(Self.name, "Timeout"))
    try fixture.run(decideScript(agent: nil, stamp: nil, zmx: fixture.zmx.path))
    #expect(fixture.dialLog.contains("\(Self.name) ensure skipped-unknown"))
  }

  @Test
  func aFailedListingNeverInvokesRunAndIsLogged() throws {
    try expectDecision(["ls"], listing: nil)
    let fixture = try Fixture(listing: nil)
    try fixture.run(decideScript(agent: nil, stamp: nil, zmx: fixture.zmx.path))
    #expect(fixture.dialLog.contains("\(Self.name) ensure skipped-ls-failed"))
  }

  @Test
  func onlyADefinitelyMissingOrEndedSessionIsLaunchedIntoEvenUnderErrexit() throws {
    // `grep` exits 1 on no match, which is exactly these listings: under `sh -e` an
    // unguarded extraction would abort before classifying, and a dead session would never
    // be relaunched.
    for listing in [
      Self.row(Self.other),
      Self.error(Self.name, "ConnectionRefused"),
      Self.row(Self.name, "\tended=5\texit_code=0"),
      "",
      // Another session's timeout is not this one's.
      Self.error(Self.other, "Timeout"),
    ] {
      try expectDecision(["ls", "run"], listing: listing)
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
      try expectDecision(["ls"], listing: listing)
    }
  }

  @Test
  func unknownDominatesALiveRowInEitherOrder() throws {
    let timeout = Self.error(Self.name, "Timeout")
    let live = Self.row(Self.name)
    try expectDecision(["ls"], listing: timeout + live)
    try expectDecision(["ls"], listing: live + timeout)
    try expectDecision(["ls"], listing: Self.error(Self.name, "ConnectionRefused") + timeout)
  }

  @Test
  func aLiveSessionOfAnotherAgentIsNeverRunIntoWhateverItsLabel() throws {
    // Labelled for this agent: ready, untouched.
    try expectDecision(["ls"], listing: Self.row(Self.name, "\tagent=codex"), agent: "codex")
    // Alive but unlabelled: adopted (stamped), never relaunched.
    for calls in try decide(listing: Self.row(Self.name), agent: "codex", stamp: ":") {
      #expect(!calls.contains("run"))
    }
    // Labelled for another agent, or for one whose name merely starts with this one: it is
    // still a running task, so nothing is typed into it; the launch is skipped.
    try expectDecision(
      ["ls"], listing: Self.row(Self.name, "\tagent=claudeCode"), agent: "codex")
    try expectDecision(["ls"], listing: Self.row(Self.name, "\tagent=codexFoo"), agent: "codex")
    // An unknown row blocks a Codex launch too, and an absent one still launches.
    try expectDecision(["ls"], listing: Self.error(Self.name, "Timeout"), agent: "codex")
    try expectDecision(["ls", "run"], listing: Self.row(Self.other), agent: "codex")
  }

  @Test
  func aMismatchedLabelIsLoggedAsASkip() throws {
    let fixture = try Fixture(listing: Self.row(Self.name, "\tagent=claudeCode"))
    try fixture.run(decideScript(agent: "codex", stamp: nil, zmx: fixture.zmx.path))
    #expect(fixture.dialLog.contains("\(Self.name) ensure skipped-agent-mismatch"))
  }

  @Test
  func aLaunchDecisionThatOutlivesItsDeadlineIsKilledAndNeverRuns() async throws {
    let fixture = try Fixture(listing: Self.row(Self.other), slow: true)
    let script = decideScript(agent: nil, stamp: nil, zmx: fixture.zmx.path)

    let finished = await ZmxSessionLauncher.runBounded(
      script: script, workingDirectory: nil, deadline: .milliseconds(500))
    #expect(!finished)
    try await Task.sleep(for: .milliseconds(500))
    #expect(fixture.calls == ["ls"])
  }

  // MARK: - The remote ensure, executed against a fake zmx

  private func remoteCalls(
    listing: String?, backend: CLISessionBackendKind = .claudeCode,
    variant: (shell: String, flags: [String])
  ) throws -> [String] {
    let fixture = try Fixture(listing: listing)
    let node = LoopNode(
      id: UUID(uuidString: "5E11BA5E-0001-4000-8000-000000000001") ?? UUID(),
      title: "Fix", loopType: .goalBased, goal: GoalSpec(summary: "tests pass"),
      backend: backend)
    let location = RemoteProjectLocation(
      user: "dev", host: "build-box", port: 2222, remotePath: fixture.directory.path)
    let built = try #require(
      ZmxSessionLauncher.remoteEnsureDialScript(
        forNode: node, at: location, settings: GraphcodeSettings()))
    try fixture.run(built.script, shell: variant.shell, flags: variant.flags)
    return fixture.calls
  }

  @Test
  func theRemoteEnsureListsOnceAndNeverRunsForAnythingButADefinitelyAbsentSession() throws {
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
        #expect(calls.filter { $0 == "ls" }.count == 1, "\(listing ?? "ls fails") \(calls)")
        #expect(!calls.contains("run"), "\(listing ?? "ls fails") \(variant) \(calls)")
      }
      for listing in ["", Self.error(name, "ConnectionRefused"), Self.row(name, "\tended=5")] {
        let calls = try remoteCalls(listing: listing, variant: variant)
        #expect(calls.filter { $0 == "ls" }.count == 1, "\(listing) \(calls)")
        #expect(calls.filter { $0 == "run" }.count == 1, "\(listing) \(variant) \(calls)")
      }
    }
  }

  /// The delivery (a `python3` here) is the slow step in which a pane can create the session.
  /// The stub flips the listing to a live row when the delivery's installer is invoked, which is exactly a
  /// session appearing while the delivery runs: no `run` may follow, whatever the shell.
  @Test
  func aSessionThatBecomesLiveDuringDeliveryIsNeverRunInto() throws {
    let name = "graphcode-5E11BA5E-0001-4000-8000-000000000001"
    for variant in Self.variants {
      let fixture = try Fixture(listing: "")
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
        user: "dev", host: "build-box", port: 2222, remotePath: fixture.directory.path)
      let built = try #require(
        ZmxSessionLauncher.remoteEnsureDialScript(
          forNode: node, at: location, settings: GraphcodeSettings()))
      try fixture.run(built.script, shell: variant.shell, flags: variant.flags)
      let listing = try String(
        contentsOf: fixture.directory.appendingPathComponent("ls.out"), encoding: .utf8)
      #expect(listing.contains(name), "the delivery never ran, so nothing was raced")
      #expect(!fixture.calls.contains("run"), "\(variant) \(fixture.calls)")
      #expect(fixture.calls.filter { $0 == "ls" }.count == 1, "\(variant) \(fixture.calls)")
    }
  }

  @Test
  func theRemoteEnsureStructureIsPinnedAsWell() throws {
    let node = LoopNode(
      title: "Fix", loopType: .goalBased, goal: GoalSpec(summary: "tests pass"))
    let location = RemoteProjectLocation(
      user: "dev", host: "build-box", port: 2222, remotePath: "/home/dev/widget")
    let command = try #require(
      ZmxSessionLauncher.remoteEnsureInvocation(forNode: node, at: location)?.last)
    let probe = try #require(command.range(of: "gc_lv=lsfail"))
    let launch = try #require(command.range(of: "'run'"))
    #expect(probe.lowerBound < launch.lowerBound)
    // Nothing that can take time, or that another pane can race, sits between the listing
    // and the launch it decides.
    let between = command[probe.lowerBound..<launch.lowerBound]
    #expect(!between.contains("b64decode"))
    #expect(!between.contains("python3"))
    #expect(!between.contains("trustedFolders"))
    #expect(command.contains("skipped-unknown"))
    #expect(command.contains("skipped-ls-failed"))
    #expect(command.contains("skipped-agent-mismatch"))
  }

  // MARK: - The remote status probe

  @Test
  func theRemoteStatusProbeNeverReadsUnknownAsAbsent() throws {
    let id = try #require(UUID(uuidString: "5E11BA5E-0001-4000-8000-000000000001"))
    let node = LoopNode(id: id, title: "x")
    let name = "graphcode-\(node.id.uuidString)"
    // Under every shell variant, plain and `-e`: they must all agree.
    func probe(_ listing: String?) throws -> String {
      let script = ZmxSessionLauncher.remoteStatusScript(forNode: node, label: "presence")
      let answers = try Self.variants.map { variant in
        try Fixture(listing: listing).run(script, shell: variant.shell, flags: variant.flags)
          .trimmingCharacters(in: .whitespacesAndNewlines)
      }
      #expect(Set(answers).count == 1, "\(answers)")
      return answers.first ?? ""
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
