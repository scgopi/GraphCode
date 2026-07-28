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
    let briefing = try #require(SessionBriefing.text(projectPath: Self.project))
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
    let briefing = try #require(SessionBriefing.text(projectPath: Self.project))
    // The path has to be in it: every command it describes takes one, and a session that
    // has to guess its own project path will guess wrong.
    #expect(briefing.contains(Self.project))
    #expect(briefing.contains("graphcode node create \(Self.project)"))
    // And the fallback, because the daemon's launchd PATH is not a human's.
    #expect(briefing.contains(SessionBriefing.installedCLIPath))
  }

  @Test
  func theBriefingLeadsWithGoalBasedAndWarnsThatTurnBasedDoesNotStart() throws {
    // Not a style preference — a defect this pins. `LoopNode.runsUnattended` is false for
    // turn-based and its `sessionPrompt` is nil, so a turn-based loop an agent creates
    // launches no process at all: five nodes appear in the sidebar and none of them run.
    // The first cut of this briefing led with `--type turn`, which made "spin up five
    // loops" produce exactly that.
    let briefing = try #require(SessionBriefing.text(projectPath: Self.project))
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
    let briefing = try #require(SessionBriefing.text(projectPath: Self.project))
    #expect(briefing.contains("cadence goes inside the prompt"))
    #expect(briefing.contains("/loop 1h"))
  }

  @Test
  func theBriefingSaysWhenNotToSpawnLoops() throws {
    // The restraint matters more than the capability. An agent told only *how* to create
    // loops will create them for every subtask it can name.
    let briefing = try #require(SessionBriefing.text(projectPath: Self.project))
    #expect(briefing.contains("Do not create loops for ordinary subtasks"))
    #expect(briefing.contains("Never create a loop whose job is to create more loops"))
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
  func anOverlongPromptDropsTheBriefingRatherThanCorruptTheCommand() throws {
    // A pasted prompt can be long enough on its own to threaten the buffer. The briefing
    // is the one thing safe to give up: without it a loop merely can't fan out, whereas a
    // truncated command line hangs the session at a continuation prompt.
    let huge = String(repeating: "do the thing ", count: 60)
    let arguments = try #require(
      ZmxSessionLauncher.arguments(
        forNode: node(prompt: huge), projectPath: Self.project))
    #expect(!arguments.contains("--append-system-prompt-file"))
    #expect(arguments.last == huge)
  }

  @Test
  func copilotGetsTheBriefingPrependedToThePromptInstead() throws {
    // `copilot` has no `--append-system-prompt`; its custom instructions come from
    // `AGENTS.md` files on disk, which graphcode has no business writing into someone's
    // repository. So the briefing rides in front of the prompt.
    let arguments = try #require(
      ZmxSessionLauncher.arguments(
        forNode: node(backend: .copilotCLI), projectPath: Self.project))

    #expect(!arguments.contains("--append-system-prompt-file"))
    let interactive = try #require(arguments.firstIndex(of: "--interactive"))
    // The human's request and nothing else. The briefing arrives through the environment,
    // not as a preamble on the prompt — it used to ride in front of it, which put
    // housekeeping ahead of the actual request and left it in the scrollback.
    #expect(arguments[interactive + 1] == "/loop 1h Check")

    // `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` is Copilot's own channel for this: it searches
    // the directories named there for instruction files.
    let script = try #require(arguments.first { $0.hasPrefix("exec ") })
    #expect(script.contains(SessionBriefing.copilotInstructionsDirectoryVariable))
    #expect(script.contains("briefings"))
    #expect(script.hasSuffix("copilot \"$@\""))
  }

  @Test
  func claudeCodeIsGivenNoEnvironmentItDoesNotNeed() throws {
    // Only Copilot discovers instructions by searching directories; setting the variable
    // for a backend that ignores it would be cargo cult.
    let arguments = try #require(
      ZmxSessionLauncher.arguments(forNode: node(), projectPath: Self.project))
    let script = try #require(arguments.first { $0.hasPrefix("exec ") })
    #expect(!script.contains(SessionBriefing.copilotInstructionsDirectoryVariable))
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
    let claude = try #require(
      ZmxSessionLauncher.arguments(forNode: node(), projectPath: Self.project))
    let mode = try #require(claude.firstIndex(of: "--permission-mode"))
    #expect(claude[mode + 1] == "auto")

    let copilot = try #require(
      ZmxSessionLauncher.arguments(
        forNode: node(backend: .copilotCLI), projectPath: Self.project))
    #expect(copilot.contains("--allow-all-tools"))
  }

  @Test
  func neitherBackendIsGivenTheKeysToTheWholeMachine() {
    // The setting is "approve the ordinary work of a coding session in this folder", not
    // "skip every check". These are the flags that would cross that line.
    let claude = CLISessionBackendKind.claudeCode.launchArguments(
      prompt: "go", tier: .standard)
    #expect(!claude.contains("--dangerously-skip-permissions"))
    #expect(!claude.contains("bypassPermissions"))

    let copilot = CLISessionBackendKind.copilotCLI.launchArguments(
      prompt: "go", tier: .standard)
    // `--allow-all`/`--yolo` also disable path verification and URL checks, which would
    // let a loop reach outside the project it was pointed at.
    #expect(!copilot.contains("--allow-all"))
    #expect(!copilot.contains("--yolo"))
    #expect(!copilot.contains("--allow-all-paths"))
    #expect(!copilot.contains("--allow-all-urls"))
  }

  @Test
  func aBackendGraphcodeCannotLaunchStillGetsNothing() {
    // Codex has no adapter — a briefing must not turn "can't launch this" into an argv
    // that looks launchable.
    #expect(
      CLISessionBackendKind.codex.launchArguments(
        prompt: "do the thing", tier: .standard,
        briefingFile: URL(fileURLWithPath: "/tmp/brief.md")
      ).isEmpty)
  }
}
