import Foundation
import Testing

@testable import GraphcodeKit

/// The command `graphcoded` builds to start a time-based node's session.
///
/// The load-bearing property is the session *name*: get it wrong and clicking the node
/// silently opens a second, empty session beside the running loop instead of attaching to
/// it. The prompt itself needs no escaping here — `zmx` shell-quotes every argument
/// (`util.shellQuote`) before typing the command into the session, so it must be passed
/// through raw. Quoting it ourselves would double-quote it.
@Suite
struct ZmxSessionLauncherTests {
  private static func node(prompt: String?) -> LoopNode {
    LoopNode(title: "Poll inbox", loopType: .timeBased, triggerPrompt: prompt)
  }

  @Test
  func targetsTheSameSessionTheAppAttachesTo() {
    let node = Self.node(prompt: "/loop 1h Check for new reports")
    let arguments = ZmxSessionLauncher.arguments(forNode: node) ?? []
    let expectedName = SurfaceRef(id: node.id, launchesClaudeCode: true).zmxSessionName

    // `-d` follows the name, not the subcommand: `zmx run -d <name>` would create a
    // session literally called "-d". And the name must match what the app's primary
    // surface attaches to.
    #expect(Array(arguments.prefix(3)) == ["run", expectedName, "-d"])
    #expect(expectedName == "graphcode-\(node.id.uuidString)")

    // Wrapped in an *interactive* login zsh. Without `-i` the shell never reads
    // `~/.zshrc`, which is where a developer's PATH usually lives, and the daemon's
    // launchd PATH doesn't include `claude` — the failure was `command not found`.
    #expect(Array(arguments.dropFirst(3).prefix(4)) == ["/bin/zsh", "-i", "-l", "-c"])
    #expect(arguments.contains(#"exec claude "$@""#))

    // No `--model` at all. This node pins no tier, and graphcode no longer picks one on
    // a human's behalf unless they switch model auto-selection on (issue #10) — the
    // backend runs on whatever `claude` is already configured to use. Tier routing still
    // exists and is still `.fast` for a time-based node; it is just opt-in now. Both
    // sides of that setting are covered hermetically in `ModelAutoSelectionTests`, which
    // is where the assertion belongs — this one reads the real settings file.
    #expect(!arguments.contains("--model"))
    // The prompt stays last — `claude` takes it positionally.
    #expect(arguments.last == "/loop 1h Check for new reports")
  }

  @Test
  func aPinnedModelTierOverridesTheDefaultRouting() {
    let node = LoopNode(
      title: "Poll", loopType: .timeBased, triggerPrompt: "/loop 1h Check", modelTier: .capable)
    let arguments = ZmxSessionLauncher.arguments(forNode: node) ?? []

    #expect(arguments.contains("--model"))
    #expect(arguments.contains("opus"))
  }

  @Test
  func theStandardTierPassesNoModelFlagAtAll() {
    // Passing no flag lets the backend's own default apply, which is different from us
    // asserting what we think its default is.
    let node = LoopNode(
      title: "Poll", loopType: .timeBased, triggerPrompt: "/loop 1h Check", modelTier: .standard)
    let arguments = ZmxSessionLauncher.arguments(forNode: node) ?? []

    #expect(!arguments.contains("--model"))
  }

  @Test
  func passesAHostilePromptThroughUntouched() {
    // Quotes, a subshell, and command separators all survive verbatim as one argument —
    // zmx quotes them on the way into the shell, so escaping them here would corrupt the
    // prompt rather than protect anything.
    let hostile = #"/loop 1h "; rm -rf ~; echo $(whoami) `id` 'quoted'"#
    let arguments = ZmxSessionLauncher.arguments(forNode: Self.node(prompt: hostile))

    // The prompt must be its own trailing argument, reaching the command through `$@`.
    // It must never appear inside the `-c` script, where it would be shell syntax.
    #expect(arguments?.last == hostile)
    #expect(arguments?.filter { $0.contains("rm -rf") }.count == 1)
    #expect(arguments?.contains(#"exec claude "$@""#) == true)
  }

  @Test
  func wrapsTheCommandInAnInteractiveLoginShell() {
    // The goal-based failure this guards: `zmx run` executes what it's given under bash,
    // which never reads `~/.zshrc`, so a bare `claude …` died with `command not found`
    // under the daemon's launchd PATH.
    let node = LoopNode(
      title: "Reach it", loopType: .goalBased,
      goal: GoalSpec(summary: "Check if the loop is working"))
    let arguments = ZmxSessionLauncher.arguments(forNode: node) ?? []

    #expect(arguments.contains("-i"))
    #expect(arguments.contains("-l"))
    #expect(!arguments.contains("claude"))  // bare `claude` is what used to fail
    #expect(arguments.contains(#"exec claude "$@""#))
  }

  @Test
  func flattensNewlinesThatWouldTruncateTheCommand() {
    // zmx ends the command it types with `\r`; an embedded one would submit the line
    // early and run only the first fragment.
    let arguments = ZmxSessionLauncher.arguments(
      forNode: Self.node(prompt: "/loop 1h Check\r\nthen report\nand stop"))

    #expect(arguments?.last == "/loop 1h Check then report and stop")
  }

  @Test
  func checksForAnExistingSessionUnderTheSameName() {
    // `zmx run` re-sends its command when the session is already live, so the launcher
    // has to look before it leaps — and it has to look under the exact name it would
    // create, or the check is meaningless.
    let node = Self.node(prompt: "/loop 1h Check")
    let check = ZmxSessionLauncher.existenceCheckArguments(forNode: node)

    #expect(check == ["get", "graphcode-\(node.id.uuidString)"])
    #expect(check.last == ZmxSessionLauncher.arguments(forNode: node)?[1])
  }

  @Test
  func opensInTheProjectWhenTheNodeHasNoWorktree() {
    // `graphcoded`'s own directory is `/` under launchd, so falling through to nil ran
    // unattended loops nowhere near the project they were created in.
    let node = Self.node(prompt: "/loop 1h Check")
    #expect(
      ZmxSessionLauncher.workingDirectory(forNode: node, projectPath: "/tmp") == "/tmp")
  }

  @Test
  func prefersTheNodesOwnWorktreeOverTheProject() {
    var node = Self.node(prompt: "/loop 1h Check")
    node.worktreeBinding = WorktreeRef(
      id: "wt", repositoryPath: "/usr", worktreePath: "/tmp", branch: "feature")
    #expect(
      ZmxSessionLauncher.workingDirectory(forNode: node, projectPath: "/usr") == "/tmp")
  }

  @Test
  func refusesAProjectPathThatIsNotARealDirectory() {
    // The global Orchestrator Graph's path is the reserved URI `graphcode://global`, and
    // a project folder can also be deleted out from under a saved graph. Either way,
    // handing it to a process as a working directory would fail the launch outright.
    let node = Self.node(prompt: "/loop 1h Check")
    #expect(
      ZmxSessionLauncher.workingDirectory(forNode: node, projectPath: LoopGraphScope.globalPath)
        == nil)
    #expect(
      ZmxSessionLauncher.workingDirectory(forNode: node, projectPath: "/no/such/folder") == nil)
    #expect(ZmxSessionLauncher.workingDirectory(forNode: node, projectPath: nil) == nil)
  }

  @Test
  func launchesNothingWithoutAPrompt() {
    // A time-based node with no prompt has nothing to run — starting a bare `claude`
    // would sit there waiting for a human who isn't there.
    #expect(ZmxSessionLauncher.arguments(forNode: Self.node(prompt: nil)) == nil)
    #expect(ZmxSessionLauncher.arguments(forNode: Self.node(prompt: "")) == nil)
  }
}
