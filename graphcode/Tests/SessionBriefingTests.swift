import Foundation
import Testing

// `@testable` because `ZmxSessionLauncher.arguments(forNode:projectPath:)` is internal to
// GraphcodeKit — the same import `ZmxSessionLauncherTests` uses to reach it.
@testable import GraphcodeKit

/// What a session is told about the graph it runs inside, and how each backend receives
/// it. Before this, a loop's session was an ordinary agent in a folder with no idea it
/// was a node in anything — so "fan this out into one loop per issue" could not be asked
/// for however the prompt was worded.
@Suite
struct SessionBriefingTests {
  private static let project = "/tmp/project"

  private func node(
    backend: CLISessionBackendKind = .claudeCode, prompt: String = "/loop 1h Check"
  ) -> LoopNode {
    LoopNode(
      title: "Poll", loopType: .timeBased, triggerPrompt: prompt, backend: backend,
      modelTier: .standard)
  }

  @Test
  func theBriefingIsFarTooBigToTypeIntoATerminal() throws {
    // The regression this pins: the briefing used to be passed as an argument, and a tty
    // in canonical mode drops everything past MAX_CANON (1024 bytes). The tail was eaten
    // mid-quote and the shell sat forever at a `>` continuation prompt. It goes in a file
    // now precisely because it cannot fit on a command line — asserting that keeps anyone
    // from "simplifying" it back onto one.
    let briefing = try #require(
      SessionBriefing.text(projectPath: Self.project, settings: GraphcodeSettings()))
    #expect(!SessionBriefing.isSafeToType(briefing))
    #expect(briefing.utf8.count > SessionBriefing.safeArgumentBudget)
  }

  @Test
  func theBriefingIsWrittenWhereTheFlagCanReadIt() throws {
    let url = try #require(SessionBriefing.write(projectPath: Self.project))
    defer { try? FileManager.default.removeItem(at: url) }
    let written = try String(contentsOf: url, encoding: .utf8)
    #expect(written.contains("graphcode node create \(Self.project)"))
    // Named for Copilot's own discovery, which searches directories rather than taking a
    // file — and sitting in a per-project directory readable enough to tell them apart.
    #expect(url.lastPathComponent == SessionBriefing.fileName)
    #expect(url.deletingLastPathComponent().lastPathComponent.contains("project"))
  }

  @Test
  func theBriefingNamesTheProjectAndTheCommandThatCreatesALoop() throws {
    let briefing = try #require(
      SessionBriefing.text(projectPath: Self.project, settings: GraphcodeSettings()))
    // The path has to be in it: every command it describes takes one, and a session that
    // has to guess its own project path will guess wrong.
    #expect(briefing.contains(Self.project))
    #expect(briefing.contains("graphcode node create \(Self.project)"))
    // And the fallback, because the daemon's launchd PATH is not a human's.
    #expect(briefing.contains(SessionBriefing.installedCLIPath))
  }

  @Test
  func theBriefingSaysANodeIsALoop() throws {
    // Issue #91: a Copilot session asked to create a child "node" did nothing, while
    // "child loop" worked — the briefing taught the command only under the word "loop".
    // The vocabulary bridge is the fix, so its absence has to fail a test.
    let briefing = try #require(
      SessionBriefing.text(projectPath: Self.project, settings: GraphcodeSettings()))
    #expect(briefing.contains("node is a loop"))
    #expect(briefing.contains("child node"))
  }

  @Test
  func theBriefingLeadsWithGoalBasedAndWarnsThatTurnBasedDoesNotStart() throws {
    // Not a style preference — a defect this pins. `LoopNode.runsUnattended` is false for
    // turn-based, so a turn-based loop an agent creates launches no process at all: five
    // nodes appear in the sidebar and none of them run until a person opens each one.
    // The first cut of this briefing led with `--type turn`, which made "spin up five
    // loops" produce exactly that.
    let briefing = try #require(
      SessionBriefing.text(projectPath: Self.project, settings: GraphcodeSettings()))
    let goalExample = try #require(briefing.range(of: "--type goal"))
    let turnExample = try #require(briefing.range(of: "--type turn"))
    #expect(goalExample.lowerBound < turnExample.lowerBound)
    #expect(briefing.contains("does not start on its own"))
  }

  @Test
  func theBriefingSaysWhereATimeBasedLoopsCadenceLives() throws {
    // graphcode holds no timer: the recurrence is a directive inside the session's own
    // prompt (`LoopNode.triggerPrompt`). A time-based loop created without one runs once
    // and stops, which looks like a broken schedule rather than a missing instruction.
    let briefing = try #require(
      SessionBriefing.text(projectPath: Self.project, settings: GraphcodeSettings()))
    #expect(briefing.contains("cadence goes inside the prompt"))
    #expect(briefing.contains("/loop 1h"))
  }

  @Test
  func theBriefingSaysWhenNotToSpawnLoops() throws {
    // The restraint matters more than the capability. An agent told only *how* to create
    // loops will create them for every subtask it can name.
    let briefing = try #require(
      SessionBriefing.text(projectPath: Self.project, settings: GraphcodeSettings()))
    #expect(briefing.contains("Do not create loops for ordinary subtasks"))
    #expect(briefing.contains("Never create a loop whose job is to create more loops"))
  }

  @Test
  func theBriefingCoversTheRarerVerbsWithoutLosingTheDeleteWarning() throws {
    // The gap this fills: a session knew how to fan out, message, and memo, but had no
    // idea the CLI could stop, rewire, or share loops — "export this loop" read as a
    // command that didn't exist. Delete rides along only with its warning attached:
    // taught bare, it looks like the way to tidy up, and it erases a loop's memory.
    let briefing = try #require(
      SessionBriefing.text(projectPath: Self.project, settings: GraphcodeSettings()))
    #expect(briefing.contains("node stop \(Self.project)"))
    #expect(briefing.contains("irreversible"))
    #expect(briefing.contains("edge create \(Self.project)"))
    #expect(briefing.contains("node export \(Self.project)"))
    #expect(briefing.contains("Export and import loops"))
    #expect(briefing.contains("graphcode://global"))
  }

  @Test
  func withoutAProjectPathThereIsNoBriefing() {
    // Every command it describes takes a path, so a briefing without one would describe
    // commands the session cannot run.
    #expect(SessionBriefing.text(projectPath: nil) == nil)
    #expect(SessionBriefing.text(projectPath: "") == nil)
  }

  @Test
  func claudeCodeGetsTheBriefingAsAFilePath() throws {
    let arguments = try #require(
      ZmxSessionLauncher.arguments(forNode: node(), projectPath: Self.project))
    let flag = try #require(arguments.firstIndex(of: "--append-system-prompt-file"))

    // A path, not the prose — that is the whole fix. And the human's prompt stays the
    // last positional argument, which is how `claude` takes it.
    let path = arguments[flag + 1]
    #expect(path.hasSuffix(".md"))
    #expect(FileManager.default.fileExists(atPath: path))
    #expect(arguments.last == "/loop 1h Check")
  }

  @Test
  func theWholeLaunchCommandFitsInATerminalsInputBuffer() throws {
    // The end-to-end version of the bug: what `zmx` actually types has to survive
    // MAX_CANON, briefing and all.
    let arguments = try #require(
      ZmxSessionLauncher.arguments(forNode: node(), projectPath: Self.project))
    #expect(ZmxSessionLauncher.fitsInATypedCommandLine(arguments))
    #expect(ZmxSessionLauncher.maximumTypedCommandBytes < 1024)
  }

  @Test
  func anOverlongPromptMovesToAFileRatherThanCorruptTheCommand() throws {
    // Issue #57. This test used to assert that an overlong prompt merely dropped the
    // briefing and stayed on the line verbatim — but the unbriefed command it accepted
    // was itself past the typed-line budget, which is exactly the corruption the budget
    // exists to prevent: the tty ate the tail mid-word and the shell parked at a
    // continuation prompt while the node read `running`. Past the budget the prompt now
    // rides in a file, the typed line carries only a short pointer, and the briefing no
    // longer needs to be sacrificed to make room.
    let huge = String(repeating: "do the thing ", count: 60)
    let overlong = node(prompt: huge)
    defer { NodeMemory.remove(projectPath: Self.project, nodeID: overlong.id) }
    let arguments = try #require(
      ZmxSessionLauncher.arguments(forNode: overlong, projectPath: Self.project))

    #expect(ZmxSessionLauncher.fitsInATypedCommandLine(arguments))
    #expect(arguments.contains("--append-system-prompt-file"))
    let typed = try #require(arguments.last)
    #expect(!typed.contains("do the thing"))
    let path = try #require(
      typed.components(separatedBy: " ").first { $0.hasSuffix(NodeMemory.promptFileName) })
    #expect(try String(contentsOfFile: path, encoding: .utf8).contains(huge))
  }

  @Test
  func copilotIsBothToldToReadTheBriefingAndAllowedTo() throws {
    // `copilot` has no `--append-system-prompt`, and the documented
    // COPILOT_CUSTOM_INSTRUCTIONS_DIRS is ignored in 1.0.75 — measured, not assumed.
    let arguments = try #require(
      ZmxSessionLauncher.arguments(
        forNode: node(backend: .copilotCLI), projectPath: Self.project))

    #expect(!arguments.contains("--append-system-prompt-file"))

    // Copilot needs *both* halves, and shipping only one is issue #2: a preamble telling
    // it to read the briefing, and permission to actually open it. Copilot verifies file
    // paths, so without the second the session is denied the file it was just told to
    // open — which looks exactly like an agent ignoring its instructions. Under YOLO
    // every path is already allowed; under the narrower tools-only mode the briefing's
    // directory must be granted by name. The launcher reads the machine's real settings,
    // so the assertion accepts whichever route this machine is on.
    if !arguments.contains("--yolo") {
      let granted = zip(arguments, arguments.dropFirst())
        .filter { $0.0 == "--add-dir" }.map(\.1)
      #expect(granted.contains { $0.contains("briefings") })
    }

    let interactive = try #require(arguments.firstIndex(of: "--interactive"))
    let opening = arguments[interactive + 1]
    #expect(opening.contains(".md"))
    #expect(opening.hasSuffix("/loop 1h Check"))
  }

  @Test
  func claudeCodeGetsNoAddDirBecauseItsFlagTakesTheFileDirectly() throws {
    let arguments = try #require(
      ZmxSessionLauncher.arguments(forNode: node(), projectPath: Self.project))
    #expect(!arguments.contains("--add-dir"))
    let script = try #require(arguments.first { $0.hasPrefix("exec ") })
    #expect(script == "exec claude \"$@\"")
  }

  @Test
  func aSessionWithNoProjectPathLaunchesExactlyAsItDidBefore() throws {
    // The briefing is additive: without a path there is nothing to say, and the argv has
    // to be byte-identical to the pre-briefing one rather than carrying an empty flag.
    let arguments = try #require(ZmxSessionLauncher.arguments(forNode: node()))
    #expect(!arguments.contains("--append-system-prompt-file"))
    #expect(arguments.last == "/loop 1h Check")
  }

  @Test
  func aBriefingNeverDisplacesTheModelFlag() throws {
    let arguments = try #require(
      ZmxSessionLauncher.arguments(
        forNode: LoopNode(
          title: "Poll", loopType: .timeBased, triggerPrompt: "/loop 1h Check",
          modelTier: .capable),
        projectPath: Self.project))
    let model = try #require(arguments.firstIndex(of: "--model"))
    #expect(arguments[model + 1] == "opus")
    #expect(arguments.contains("--append-system-prompt-file"))
  }

  @Test
  func everySessionLaunchesWithPermissionsAlreadyAnswered() throws {
    // A loop is unattended by construction: nobody is watching the pane when the backend
    // asks whether it may edit a file, so a session on its interactive default sits at
    // that prompt while the graph reports it `running`.
    // Settings are passed explicitly rather than left to default: `ZmxSessionLauncher`
    // otherwise falls back to `GraphcodeSettingsStore.load()` and reads whatever this
    // machine chose in the UI, so the assertion below turned on a toggle no test touched.
    let defaults = GraphcodeSettings()

    let claude = try #require(
      ZmxSessionLauncher.arguments(
        forNode: node(), projectPath: Self.project, settings: defaults))
    let mode = try #require(claude.firstIndex(of: "--permission-mode"))
    #expect(claude[mode + 1] == "auto")

    let copilot = try #require(
      ZmxSessionLauncher.arguments(
        forNode: node(backend: .copilotCLI), projectPath: Self.project, settings: defaults))
    #expect(copilot.contains("--yolo") || copilot.contains("--allow-all-tools"))

    // Codex answers the same question in its own vocabulary, and a loop left on its `ask`
    // default waits at the first approval prompt exactly as the other two would.
    let codex = try #require(
      ZmxSessionLauncher.arguments(
        forNode: node(backend: .codex), projectPath: Self.project, settings: defaults))
    let approval = try #require(codex.firstIndex(of: "--ask-for-approval"))
    #expect(codex[approval + 1] == "never")
  }

  @Test
  func theDefaultPermissionsMatchEachBackendsBargain() {
    // Claude Code's `auto` approves the ordinary work of a coding session with its
    // guardrails intact — bypassing them stays a choice, never a default.
    let claude = CLISessionBackendKind.claudeCode.launchArguments(
      prompt: "go", tier: .standard, settings: GraphcodeSettings())
    #expect(!claude.contains("--dangerously-skip-permissions"))
    #expect(!claude.contains("bypassPermissions"))

    // Copilot's default is deliberately its `--yolo`: it confirms tools, paths, and
    // URLs separately, and the narrower tools-only default left unattended loops
    // stalling at URL and path dialogs nobody was watching — see
    // `GraphcodeSettings.CopilotPermissions`.
    let copilot = CLISessionBackendKind.copilotCLI.launchArguments(
      prompt: "go", tier: .standard, settings: GraphcodeSettings())
    #expect(copilot.contains("--yolo"))
  }

  @Test
  func copilotIsGivenTheDirectoriesItsWorkSpans() throws {
    // Issue #4. Copilot gates tools, paths and URLs separately: `--allow-all-tools` says
    // nothing about *where* a tool may read, so a loop bound to a worktree is denied the
    // repository it was branched from — indistinguishable, from the outside, from an agent
    // ignoring its instructions.
    let worktree = WorktreeRef(
      id: "wt", repositoryPath: Self.project, worktreePath: "/tmp/wt", branch: "x")
    let node = LoopNode(
      title: "Poll", loopType: .timeBased, triggerPrompt: "/loop 1h Check",
      backend: .copilotCLI, worktreeBinding: worktree)
    let arguments = try #require(
      ZmxSessionLauncher.arguments(forNode: node, projectPath: Self.project))

    // Under YOLO every path is already open and named grants would be noise (see
    // `theWiderAndStricterSettingsAddNoDirectories`); under tools-only mode each
    // directory the work spans must be granted by name. The launcher reads this
    // machine's real settings, so the assertion follows whichever mode it's on.
    if arguments.contains("--yolo") {
      #expect(!arguments.contains("--add-dir"))
    } else {
      let granted = zip(arguments, arguments.dropFirst())
        .filter { $0.0 == "--add-dir" }.map(\.1)
      #expect(granted.contains(Self.project))
      #expect(granted.contains("/tmp/wt"))
      #expect(granted.contains { $0.contains("briefings") })
      // Named directories, not the whole disk.
      #expect(!arguments.contains("--allow-all-paths"))
    }
  }

  @Test
  func theWiderAndStricterSettingsAddNoDirectories() {
    // `.allowEverything` has already opened every path, and under `.ask` a human is
    // answering for each one — in both cases `--add-dir` would be noise.
    #expect(
      GraphcodeSettings.CopilotPermissions.allowEverything.readableDirectories(["/a"]).isEmpty)
    #expect(GraphcodeSettings.CopilotPermissions.ask.readableDirectories(["/a"]).isEmpty)
    #expect(
      GraphcodeSettings.CopilotPermissions.allowTools.readableDirectories(["/a", "/a", ""])
        == ["--add-dir", "/a"])
  }

  @Test
  func theGlobalGraphsReservedPathIsNotOfferedAsADirectory() {
    // `graphcode://global` names no directory; handing it to `--add-dir` would be asking
    // the CLI to grant access to something that cannot exist.
    let paths = ZmxSessionLauncher.workspacePaths(
      forNode: LoopNode(title: "x"), projectPath: LoopGraphScope.globalPath)
    #expect(paths.isEmpty)
  }

  @Test
  func codexIsBothToldToReadTheBriefingAndAllowedTo() throws {
    // Codex used to return no argv at all, because it had no adapter. It has one now
    // (issue #1), and it needs the same two halves Copilot does: it sandboxes writes to
    // its workspace, so a session told to read a briefing outside that workspace cannot
    // reach it.
    let arguments = CLISessionBackendKind.codex.launchArguments(
      prompt: "do the thing", tier: .standard,
      briefingPath: "/tmp/briefings/x/AGENTS.md")

    let addDir = try #require(arguments.firstIndex(of: "--add-dir"))
    #expect(arguments[addDir + 1] == "/tmp/briefings/x")
    // The prompt stays last and positional, the way `codex [OPTIONS] [PROMPT]` takes it.
    #expect(arguments.last?.hasSuffix("do the thing") == true)
    #expect(arguments.last?.contains("AGENTS.md") == true)
  }

  /// The pointer travels through more layers than any other prose graphcode emits —
  /// argv, zmx's typed command line, a canonical-mode tty, sometimes ssh — and an em
  /// dash right after the path came out the far end as `AGENTS. it explains`, the
  /// `.md` eaten with the dash. ASCII survives every one of those layers; nothing else
  /// is allowed in.
  @Test
  func thePointerIsPureASCIIWithThePathIntact() {
    let pointer = SessionBriefing.pointer(
      toBriefingAt: "/Users/x/.graphcode/briefings/p/AGENTS.md")
    #expect(pointer.allSatisfy { $0.isASCII })
    #expect(pointer.contains("/Users/x/.graphcode/briefings/p/AGENTS.md and follow it."))
  }
}

/// The briefing teaches whichever cadence model is the current default — an agent
/// following yesterday's guidance under today's default would create loops the human
/// just said they no longer want.
@Suite
struct BriefingCadenceGuidanceTests {
  @Test
  func theTimeLoopBulletFollowsTheHeartbeatExperiment() throws {
    let off = try #require(
      SessionBriefing.text(projectPath: "/tmp/p", settings: GraphcodeSettings()))
    #expect(off.contains("The cadence goes inside the prompt"))
    #expect(!off.contains("--heartbeat"))

    let on = try #require(
      SessionBriefing.text(
        projectPath: "/tmp/p", settings: GraphcodeSettings(daemonHeartbeatEnabled: true)))
    #expect(on.contains("--heartbeat <seconds>"))
    #expect(on.contains("The daemon drives it"))
    #expect(!on.contains("The cadence goes inside the prompt"))
  }
}
