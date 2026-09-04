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

  // MARK: - Husk-aware session state (issue #215)

  // A session whose task has ended is not a session a keystroke can reach: `zmx run`'s
  // wrapper shell stays at its prompt, so the session answers `zmx get` forever and a
  // send into it "succeeds" — the "delivered" that no one received. Every gate now
  // judges the task inside, read off the `zmx ls` line zmx prints for the session.

  private func lsLine(name: String, fields: String = "") -> String {
    "name=\(name)\tpid=4242\tclients=0\tcreated=1756400000\(fields)"
  }

  @Test
  func aLiveTaskIsAlive() {
    let output = lsLine(name: "graphcode-a") + "\tpresence=idle activity=editing Foo.swift\n"
    #expect(
      ZmxSessionLauncher.parseSessionTaskState(lsOutput: output, sessionName: "graphcode-a")
        == .alive)
  }

  @Test
  func anEndedTaskIsExitedWithZmxCaughtExitCode() {
    // The shape `zmx ls` prints for a completed task: `ended=<ts>\texit_code=<n>`.
    let output = lsLine(name: "graphcode-a", fields: "\tended=1756400100\texit_code=1")
    #expect(
      ZmxSessionLauncher.parseSessionTaskState(lsOutput: output, sessionName: "graphcode-a")
        == .exited(exitCode: 1))
  }

  @Test
  func anEndedTaskWithNoExitCodeIsStillExited() {
    let output = lsLine(name: "graphcode-a", fields: "\tended=1756400100")
    #expect(
      ZmxSessionLauncher.parseSessionTaskState(lsOutput: output, sessionName: "graphcode-a")
        == .exited(exitCode: nil))
  }

  @Test
  func aMissingRowIsAbsent() {
    #expect(
      ZmxSessionLauncher.parseSessionTaskState(lsOutput: "", sessionName: "graphcode-a")
        == .absent)
    #expect(
      ZmxSessionLauncher.parseSessionTaskState(
        lsOutput: lsLine(name: "graphcode-b") + "\n", sessionName: "graphcode-a")
        == .absent)
  }

  @Test
  func anUnreachableSessionIsAbsentNotAlive() {
    // zmx prints an error row for a session whose daemon it cannot reach — as good as
    // gone, and never a reason to believe a keystroke would land.
    let output = "name=graphcode-a\terr=ConnectionRefused\tstatus=cleaning up\n"
    #expect(
      ZmxSessionLauncher.parseSessionTaskState(lsOutput: output, sessionName: "graphcode-a")
        == .absent)
  }

  @Test
  func aSessionNameIsNeverFoundInsideAnotherSessionsName() {
    // Substring matching would read `graphcode-a` alive while only `graphcode-AB`
    // exists — one loop wearing another's liveness.
    let output = lsLine(name: "graphcode-AB") + "\n"
    #expect(
      ZmxSessionLauncher.parseSessionTaskState(lsOutput: output, sessionName: "graphcode-a")
        == .absent)
  }

  @Test
  func textThatMerelyContainsEndedDoesNotReadAsAHusk() {
    // The `ended=` field is tab-preceded; a prompt or command that merely contains the
    // text — no tab — must not turn a live session into a husk, or the ensure would
    // re-type the launch command into a running agent.
    let output =
      lsLine(name: "graphcode-a", fields: "\tcmd=zmx run 'the report ended=ok'")
      + "\tattached labels\n"
    #expect(
      ZmxSessionLauncher.parseSessionTaskState(lsOutput: output, sessionName: "graphcode-a")
        == .alive)
  }

  @Test
  func theShellAliveCheckFiltersHusksAndMatchesTheExactName() {
    let node = Self.node(prompt: "/loop 1h Check")
    let command = ZmxSessionLauncher.aliveCheckCommand(zmxPath: "/usr/local/bin/zmx", forNode: node)
    let name = "graphcode-\(node.id.uuidString)"

    // Husk rows (ended=) and error rows (err=) are filtered before the name is matched,
    // and the name is matched tab-terminated so a prefix of another session's name
    // cannot pass.
    #expect(command.contains("ls 2>/dev/null"))
    #expect(command.contains("grep -v -e $'\\tended=' -e $'\\terr='"))
    #expect(command.contains("grep -q"))
    #expect(command.contains("name=\(name)\t"))
    #expect(command.contains("'/usr/local/bin/zmx'"))
  }

  @Test
  func aCodexDaemonCheckRejectsABareAttachShell() {
    let node = LoopNode(
      title: "Codex", loopType: .goalBased, goal: GoalSpec(summary: "work"), backend: .codex)
    let command = ZmxSessionLauncher.aliveCheckCommand(
      zmxPath: "/usr/local/bin/zmx", forNode: node)
    #expect(command.contains("cmd=.*codex"))
  }

  @Test
  func appWaitsForTheDaemonBeforeAttachingCodex() {
    let command = ZmxSessionLauncher.waitingAttachCommand(
      zmxPath: "/usr/local/bin/zmx", sessionName: "graphcode-a", executable: "codex")
    #expect(command.first == "/bin/zsh")
    #expect(command.last?.contains("until") == true)
    #expect(command.last?.contains("cmd=.*codex") == true)
    #expect(command.last?.contains("exec '/usr/local/bin/zmx' attach 'graphcode-a'") == true)
    // A session the daemon never creates must not be polled at 10 Hz forever: the wait
    // gives up after a minute with a message instead of spinning.
    #expect(command.last?.contains("-ge 600") == true)
    #expect(command.last?.contains("exit 1") == true)
  }

  @Test
  func theRemoteSeedPreTrustsClaudeCodesFolder() {
    // Issue #215's fix on the remote path: a fresh unattended `claude` exits 1 on its
    // trust dialog, so the create branch seeds `hasTrustDialogAccepted` before it runs.
    let node = LoopNode(
      title: "Remote", loopType: .goalBased, goal: GoalSpec(summary: "work"),
      backend: .claudeCode)
    var remote = node
    remote.backend = .copilotCLI
    let location = RemoteProjectLocation(
      host: "box", port: nil, remotePath: "/srv/repo", isCodespace: false)

    let claude = ZmxSessionLauncher.remoteEnsureInvocation(forNode: node, at: location) ?? []
    let script = claude.last ?? ""
    #expect(script.contains("hasTrustDialogAccepted"))
    #expect(script.contains("~/.claude.json"))

    let copilot = ZmxSessionLauncher.remoteEnsureInvocation(forNode: remote, at: location) ?? []
    #expect(!(copilot.last ?? "").contains("hasTrustDialogAccepted"))
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
  func opensGlobalGraphLoopsAtHome() {
    // A global-graph loop — an email watcher, say — belongs to no folder: its reserved
    // `graphcode://` path names no directory, and before this it fell through to nil,
    // which under launchd meant the daemon's own cwd, `/`.
    let node = Self.node(prompt: "/loop 1h Check the inbox")
    #expect(
      ZmxSessionLauncher.workingDirectory(forNode: node, projectPath: LoopGraphScope.globalPath)
        == NSHomeDirectory())
  }

  @Test
  func refusesAProjectPathThatIsNotARealDirectory() {
    // A project folder can be deleted out from under a saved graph — handing its stale
    // path to a process as a working directory would fail the launch outright.
    let node = Self.node(prompt: "/loop 1h Check")
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

  @Test
  func aMultiKBGoalIsDeliveredByFileAndTypedAsAPointer() {
    // Issue #57: the launch command is typed into a canonical-mode tty, which discards
    // everything past MAX_CANON (1024 bytes). A multi-KB goal was eaten mid-word, the
    // shell parked at a continuation prompt, and the node read `running` while no
    // backend process ever existed. Past the typed-line budget, the prompt must ride in
    // a file with only a short pointer on the line.
    let goal = String(
      repeating: "Resolve the CONFLICT SCOPE in one debate round before moving on. ", count: 40)
    let node = LoopNode(title: "Debate", loopType: .goalBased, goal: GoalSpec(summary: goal))
    defer { NodeMemory.remove(projectPath: "/tmp", nodeID: node.id) }

    let arguments = ZmxSessionLauncher.arguments(forNode: node, projectPath: "/tmp") ?? []

    // The whole point: what gets typed survives the tty.
    #expect(ZmxSessionLauncher.fitsInATypedCommandLine(arguments))
    // The typed prompt is the pointer, not the goal.
    let typed = arguments.last ?? ""
    #expect(!typed.contains("CONFLICT SCOPE"))
    #expect(typed.contains(NodeMemory.promptFileName))
    // And the file carries the full goal, nothing dropped mid-string.
    let file = NodeMemory.directory(forProjectPath: "/tmp", nodeID: node.id)
      .appendingPathComponent(NodeMemory.promptFileName)
    let content = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    #expect(content.contains(goal))
  }

  @Test
  func aPromptWithinTheLineBudgetIsStillTypedDirectly() {
    // The file is the last resort, not the new default: a short goal keeps today's
    // behaviour, typed verbatim so nothing has to read a file to know its job.
    let node = LoopNode(
      title: "Small", loopType: .goalBased, goal: GoalSpec(summary: "Say hello"))
    defer { NodeMemory.remove(projectPath: "/tmp", nodeID: node.id) }

    let arguments = ZmxSessionLauncher.arguments(forNode: node, projectPath: "/tmp") ?? []

    #expect(arguments.last?.contains("Say hello") == true)
    #expect(arguments.last?.contains(NodeMemory.promptFileName) != true)
    let file = NodeMemory.directory(forProjectPath: "/tmp", nodeID: node.id)
      .appendingPathComponent(NodeMemory.promptFileName)
    #expect(!FileManager.default.fileExists(atPath: file.path))
  }

  @Test
  func theOversizedPromptFileKeepsItsNewlines() {
    // The typed line must flatten newlines (zmx submits at `\r`); the file has no such
    // hazard, so a pasted multi-line brief survives with its structure intact.
    let brief = "# Debate brief\n\n" + String(repeating: "One point per line.\n", count: 60)
    let node = LoopNode(title: "Brief", loopType: .timeBased, triggerPrompt: brief)
    defer { NodeMemory.remove(projectPath: "/tmp", nodeID: node.id) }

    _ = ZmxSessionLauncher.arguments(forNode: node, projectPath: "/tmp")

    let file = NodeMemory.directory(forProjectPath: "/tmp", nodeID: node.id)
      .appendingPathComponent(NodeMemory.promptFileName)
    let content = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    #expect(content.contains("# Debate brief\n"))
  }

  @Test
  func aReportedActivityLabelIsCollapsedToOneBoundedLine() {
    // A label is whatever a hook wrote. One that arrives as a paragraph must not reach
    // the graph, the broadcast, and every card's one-line row — so it is cut here, once,
    // where the cut is a decision rather than an accident of layout.
    #expect(
      ZmxSessionLauncher.parseActivityLabel("activity=  editing\n  UsageReport.swift ")
        == "editing UsageReport.swift")
    #expect(ZmxSessionLauncher.parseActivityLabel("   ") == nil)
    #expect(
      ZmxSessionLauncher.parseActivityLabel(String(repeating: "x", count: 500))?.count
        == ZmxSessionLauncher.maxActivityLength)
  }

  @Test
  func activityIsReadFromTheSessionsOwnLabelStore() {
    // The same channel presence and usage come over — one session, three labels, and
    // nothing graphcode has to scrape from a terminal to guess at.
    let node = LoopNode(title: "loop")
    #expect(
      ZmxSessionLauncher.activityLabelArguments(forNode: node)
        == ["get", SurfaceRef(id: node.id, launchesClaudeCode: true).zmxSessionName, "activity"])
  }

  // MARK: - Message chunking

  // Why chunks exist at all: one `zmx send` is one uninterrupted PTY write, and one
  // large enough to outrun what the daemon will buffer has nowhere to go — while every
  // layer above, `zmx send`'s exit 0 included, reports the message delivered.
  //
  // Chunking is *not* what keeps a message intact, which is what issue #277 cost two
  // orchestration runs to learn: the splitter here was correct and every multi-chunk
  // message still arrived headless. `sendWrites` carries that half — these tests cover
  // only the cutting, and MessageDeliveryTests covers whether anything arrives.

  @Test
  func aShortMessageIsOneChunkUnchanged() {
    #expect(ZmxSessionLauncher.messageChunks("task done") == ["task done"])
    #expect(ZmxSessionLauncher.messageChunks("") == [])
  }

  @Test
  func chunksReassembleToExactlyTheFlattenedMessage() {
    let message = String(repeating: "GC-01-ABCDEFGHIJ ", count: 500)  // 8.5 KB
    let chunks = ZmxSessionLauncher.messageChunks(message)

    #expect(chunks.count > 1)
    #expect(chunks.joined() == ZmxSessionLauncher.flattened(message))
  }

  @Test
  func noChunkExceedsWhatOnePTYWriteCanCarry() {
    let message = String(repeating: "x", count: 10_000)
    for chunk in ZmxSessionLauncher.messageChunks(message) {
      #expect(chunk.utf8.count <= ZmxSessionLauncher.maxSendChunkBytes)
    }
  }

  @Test
  func aMultibyteCharacterIsNeverSplitAcrossChunks() {
    // A UTF-8 sequence split across two PTY writes reassembles in the composer only by
    // luck of scheduling. Repeating a 4-byte character makes every possible cut point
    // mid-character unless the chunker counts bytes per character.
    let message = String(repeating: "🐛", count: 1_500)  // 6 KB of 4-byte characters
    let chunks = ZmxSessionLauncher.messageChunks(message)

    #expect(chunks.count > 1)
    #expect(chunks.joined() == message)
    for chunk in chunks {
      #expect(chunk.utf8.count <= ZmxSessionLauncher.maxSendChunkBytes)
      #expect(chunk.unicodeScalars.allSatisfy { $0.value == "🐛".unicodeScalars.first!.value })
    }
  }

  @Test
  func chunkingFlattensNewlinesBeforeCutting() {
    // Flatten-then-cut, not cut-then-flatten: a cut landing between `\r` and `\n`
    // would turn one newline into two spaces and the reassembled message would not
    // match what a single small send produces.
    let chunks = ZmxSessionLauncher.messageChunks("line one\r\nline two")
    #expect(chunks == ["line one line two"])
  }

  @Test
  func anEscapeNeverSurvivesIntoWhatIsTyped() {
    // Typed bare it is a composer's cancel key; inside a bracketed paste an `ESC[201~`
    // would end the paste early and type the rest as the keystrokes `sendWrites` exists
    // to avoid. Neither is ever what the message meant.
    #expect(ZmxSessionLauncher.flattened("before\u{1B}[201~after") == "before[201~after")
  }

  // MARK: - How a message is framed into writes (issue #277)

  @Test
  func aShortMessageIsTypedExactlyAsItAlwaysWas() {
    // The path that was never broken, kept bit-for-bit: one plain write, no markers.
    #expect(ZmxSessionLauncher.sendWrites("task done") == ["task done"])
    #expect(ZmxSessionLauncher.sendWrites("") == [])
  }

  @Test
  func aLongMessageIsWrappedInOneBracketedPaste() {
    let message = String(repeating: "GC-277-ABCDEFGH ", count: 500)  // 8 KB
    let writes = ZmxSessionLauncher.sendWrites(message)

    #expect(writes.count > 1)
    // Exactly one paste, opened by the first write and closed by the last: a marker on a
    // write of its own could be separated from the payload it frames by a failed send.
    #expect(writes.first?.hasPrefix(ZmxSessionLauncher.pasteStart) == true)
    #expect(writes.last?.hasSuffix(ZmxSessionLauncher.pasteEnd) == true)
    #expect(writes.filter { $0.contains(ZmxSessionLauncher.pasteStart) }.count == 1)
    #expect(writes.filter { $0.contains(ZmxSessionLauncher.pasteEnd) }.count == 1)
  }

  @Test
  func theWritesReassembleToTheMessageAndNothingElse() {
    let message = String(repeating: "GC-277-ABCDEFGH ", count: 500)
    let flat = ZmxSessionLauncher.flattened(message)
    let typed = ZmxSessionLauncher.sendWrites(message).joined()
      .replacingOccurrences(of: ZmxSessionLauncher.pasteStart, with: "")
      .replacingOccurrences(of: ZmxSessionLauncher.pasteEnd, with: "")

    #expect(typed == flat + ZmxSessionLauncher.deliveryTrailer(for: flat))
  }

  @Test
  func aLongMessageSaysWhatItsHeadShouldHaveBeen() {
    // #277's damage was invisible because the head carried the attribution: a clipped
    // message read as a whole one, and grepping for `[graphcode]` found only the
    // undamaged. The trailer rides the surviving half so a receiver can tell.
    let message = "[graphcode] Reviewer: " + String(repeating: "detail ", count: 400)
    let flat = ZmxSessionLauncher.flattened(message)
    let trailer = ZmxSessionLauncher.deliveryTrailer(for: flat)

    #expect(trailer.contains("[graphcode]"))
    #expect(trailer.contains("\(flat.count)-character"))
    #expect(trailer.contains("[graphcode] Reviewer: detail"))
    #expect(ZmxSessionLauncher.sendWrites(message).last?.contains(trailer.suffix(20)) == true)
  }

  @Test
  func noWriteExceedsWhatOnePTYWriteCanCarry() {
    let message = String(repeating: "x", count: 10_000)
    for write in ZmxSessionLauncher.sendWrites(message) {
      // The markers ride on top of a full-sized chunk, so allow for them.
      let framing =
        ZmxSessionLauncher.pasteStart.utf8.count + ZmxSessionLauncher.pasteEnd.utf8.count
      #expect(write.utf8.count <= ZmxSessionLauncher.maxSendChunkBytes + framing)
    }
  }

  @Test
  func theRemoteSendCarriesTheSameFramingAsTheLocalOne() throws {
    // The composer on the far side is the same program with the same appetite, and the
    // remote path is the one #277 could not test. It chains the same writes into one ssh
    // round-trip, so it has to be chaining the *framed* ones.
    let node = LoopNode(title: "Remote", loopType: .goalBased, goal: GoalSpec(summary: "work"))
    let location = try #require(
      RemoteProjectLocation.parse(projectPath: "ssh://someone@box/~/project"))
    let message = String(repeating: "GC-277-ABCDEFGH ", count: 500)
    let script = ZmxSessionLauncher.remoteSendInvocation(message, toNode: node, at: location)
      .joined(separator: " ")

    #expect(script.contains("200~"))
    #expect(script.contains("201~"))
  }
}
