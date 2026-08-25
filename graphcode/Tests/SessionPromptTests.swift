import Foundation
import Testing

@testable import GraphcodeKit

/// Where the preambles graphcode wraps around a session's opening prompt are allowed to
/// sit. Every backend reads a leading `/` as a command and anything else as prose, and a
/// time-based node's prompt *is* a command — the `/loop …` directive that makes the
/// session re-trigger itself, since graphcode holds no timer of its own. A preamble in
/// front of it is not a preamble, it is a silently disabled loop type (issue #179).
@Suite
struct SessionPromptTests {
  /// Copilot is the backend that both hosts time-based loops and takes its briefing as a
  /// preamble, so the briefing pushed the directive mid-message, Copilot read it as
  /// literal text, no schedule was ever created, and the loop ran one pass and sat
  /// `idle` forever.
  @Test
  func theLoopDirectiveKeepsTheFrontOfACopilotPrompt() throws {
    let arguments = CLISessionBackendKind.copilotCLI.launchArguments(
      prompt: "/loop 1h Check the queue", tier: .standard,
      briefingPath: "/tmp/briefings/x/AGENTS.md")

    let interactive = try #require(arguments.firstIndex(of: "--interactive"))
    let opening = arguments[interactive + 1]
    #expect(opening.hasPrefix("/loop 1h Check the queue"))
    // Trailing, not dropped: `/loop <interval> <task>` takes the rest of the line as the
    // task, so the briefing reaches every scheduled pass rather than none of them.
    #expect(opening.contains("/tmp/briefings/x/AGENTS.md"))
  }

  /// The other half of the same rule, and the one issue #2 bought: an ordinary prose
  /// prompt still opens with the pointer, because a session that reads its briefing after
  /// the work is a session that never fanned out.
  @Test
  func anOrdinaryPromptStillOpensWithTheBriefingPointer() throws {
    let arguments = CLISessionBackendKind.copilotCLI.launchArguments(
      prompt: "fix the failing test", tier: .standard,
      briefingPath: "/tmp/briefings/x/AGENTS.md")

    let interactive = try #require(arguments.firstIndex(of: "--interactive"))
    #expect(arguments[interactive + 1].hasPrefix("Before anything else"))
    #expect(arguments[interactive + 1].hasSuffix("fix the failing test"))
  }

  /// The wake digest is the second preamble a launched session carries (`NodeMemory`),
  /// and it buried the directive on every relaunch after the first pass — including on
  /// Claude Code, whose briefing rides a flag and so looked immune.
  @Test
  func theWakeDigestPointerTrailsADirectiveToo() {
    let composed = SessionPrompt.composed(
      preamble: NodeMemory.wakePointer(toDigestAt: "/tmp/m/WAKE.md"),
      prompt: "/loop 30m Triage new issues")
    #expect(composed.hasPrefix("/loop 30m Triage new issues"))
    #expect(composed.contains("/tmp/m/WAKE.md"))
  }

  @Test
  func aTrailingPreambleGetsItsOwnSentence() {
    // Without the boundary the task and the preamble run together into one instruction:
    // "...Triage new issues Read your loop memory at...".
    #expect(
      SessionPrompt.composed(preamble: "Read the file.", prompt: "/loop 1h Triage")
        == "/loop 1h Triage. Read the file.")
    #expect(
      SessionPrompt.composed(preamble: "Read the file.", prompt: "/loop 1h Triage.")
        == "/loop 1h Triage. Read the file.")
  }

  /// Copilot's `/loop` is an alias of `/every`, which submits its prompt only *after* the
  /// interval has elapsed. An hourly loop therefore arms correctly and then does nothing
  /// for an hour, which reads as a loop that never started — so the same task is typed in
  /// as an ordinary message to give it the pass the schedule will not.
  @Test
  func theFirstPassIsTheTaskWithoutTheDirectiveThatSchedulesIt() {
    #expect(
      SessionPrompt.firstPass(of: "/loop 1h Triage new issues") == "Triage new issues")
    #expect(
      SessionPrompt.firstPass(of: "/every 30m Check the queue") == "Check the queue")
    // Everything past the interval, pointers included: the first pass reads the same
    // briefing and memory every scheduled pass will.
    #expect(
      SessionPrompt.firstPass(of: "/loop 1h Triage. Read the briefing at /tmp/a/AGENTS.md.")
        == "Triage. Read the briefing at /tmp/a/AGENTS.md.")
  }

  @Test
  func aPromptThatIsNotADirectiveHasNoFirstPass() {
    #expect(SessionPrompt.firstPass(of: "fix the failing test") == nil)
    // A prompt opening with a path is not a command to be unwrapped.
    #expect(SessionPrompt.firstPass(of: "/tmp/x is broken") == nil)
    // An interval with no task behind it schedules nothing worth repeating.
    #expect(SessionPrompt.firstPass(of: "/loop 1h") == nil)
    #expect(SessionPrompt.firstPass(of: "/loop 1h   ") == nil)
  }

  /// `/loop` is behind Copilot's experimental flag. Without it the directive is not a
  /// command at all and the session reads it as prose — the same silence issue #179
  /// produced by a different route.
  @Test
  func aCopilotLoopDirectiveAsksForTheExperimentalCommands() {
    let looping = CLISessionBackendKind.copilotCLI.launchArguments(
      prompt: "/loop 1h Check the queue", tier: .standard)
    #expect(looping.contains("--experimental"))

    // An ordinary session keeps the CLI's own defaults.
    let ordinary = CLISessionBackendKind.copilotCLI.launchArguments(
      prompt: "fix the failing test", tier: .standard)
    #expect(!ordinary.contains("--experimental"))
  }

  /// The first pass belongs only to a node whose *session* holds the timer. A heartbeat
  /// node's daemon drives every pass including the first, and typing a task in as well
  /// would double it.
  @Test
  func onlyASchedulingCopilotNodeGetsAFirstPass() {
    func node(
      backend: CLISessionBackendKind = .copilotCLI, type: LoopType = .timeBased,
      prompt: String = "/loop 1h Check", heartbeat: Double? = nil
    ) -> LoopNode {
      LoopNode(
        title: "Poll", loopType: type, triggerPrompt: prompt,
        heartbeatIntervalSeconds: heartbeat, backend: backend)
    }
    // A parseable interval means the daemon holds the cadence and delivers the first
    // pass itself — the kickoff exists only for a directive whose interval it cannot
    // read, where the session is still on its own.
    #expect(ZmxSessionLauncher.firstPassMessage(for: node()) == nil)
    #expect(ZmxSessionLauncher.firstPassMessage(for: node(prompt: "/loop soon Check")) == "Check")
    #expect(ZmxSessionLauncher.firstPassMessage(for: node(heartbeat: 900)) == nil)
    #expect(ZmxSessionLauncher.firstPassMessage(for: node(backend: .claudeCode)) == nil)
    #expect(
      ZmxSessionLauncher.firstPassMessage(for: node(type: .sketch, prompt: "poke about")) == nil)
  }

  /// The user-visible difference this pins: a goal-based loop's task lands as a typed
  /// user message and Copilot works on it at creation; `/every`'s scheduled prompts
  /// arrive system-shaped and it does not. So a Copilot time loop's cadence is the
  /// daemon's — derived from the directive it was created with, no migration — and its
  /// session opens by doing, not by scheduling.
  @Test
  func aCopilotTimeLoopIsDaemonDrivenByDerivation() {
    let copilot = LoopNode(
      title: "Poll", loopType: .timeBased, triggerPrompt: "/loop 1h Check the queue",
      backend: .copilotCLI)
    #expect(copilot.effectiveHeartbeatInterval == 3600)
    #expect(copilot.hasDerivedHeartbeat)
    #expect(copilot.heartbeatTask == "Check the queue")
    let opening = copilot.sessionPrompt ?? ""
    #expect(opening.contains("Run one pass of this task now: Check the queue"))
    #expect(!opening.contains("/loop 1h"))

    // Claude Code's /loop works as a command; its model is untouched.
    let claude = LoopNode(
      title: "Poll", loopType: .timeBased, triggerPrompt: "/loop 1h Check the queue",
      backend: .claudeCode)
    #expect(claude.effectiveHeartbeatInterval == nil)
    #expect(claude.sessionPrompt == "/loop 1h Check the queue")

    // The experiment's explicit opt-in still wins over the derivation.
    let explicit = LoopNode(
      title: "Poll", loopType: .timeBased, triggerPrompt: "/loop 1h Check",
      heartbeatIntervalSeconds: 900, backend: .copilotCLI)
    #expect(explicit.effectiveHeartbeatInterval == 900)
    #expect(!explicit.hasDerivedHeartbeat)
  }

  @Test
  func theDirectiveIntervalVocabularyMatchesTheDialog() {
    #expect(SessionPrompt.interval(of: "/loop 90s go") == 90)
    #expect(SessionPrompt.interval(of: "/every 30m go") == 1800)
    #expect(SessionPrompt.interval(of: "/loop 2h go") == 7200)
    #expect(SessionPrompt.interval(of: "/loop 3d go") == 259_200)
    #expect(SessionPrompt.interval(of: "/loop 45 go") == 2700)
    #expect(SessionPrompt.interval(of: "/loop soon go") == nil)
    #expect(SessionPrompt.interval(of: "just prose") == nil)
  }

  /// The marker is what stops the opening pass repeating, and it records *which* session
  /// was served rather than the fact of serving: a daemon restart over the same Copilot
  /// session must send nothing, while a new session — a new directory — is always owed
  /// its own pass.
  @Test
  func theFirstPassMarkerIsPerSessionAndForgottenWithIt() throws {
    let base = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let node = UUID()

    #expect(NodeMemory.firstPassMarker(projectPath: "/tmp/p", nodeID: node, baseURL: base) == nil)
    NodeMemory.recordFirstPass("session-a", projectPath: "/tmp/p", nodeID: node, baseURL: base)
    #expect(
      NodeMemory.firstPassMarker(projectPath: "/tmp/p", nodeID: node, baseURL: base)
        == "session-a")

    NodeMemory.clearFirstPass(projectPath: "/tmp/p", nodeID: node, baseURL: base)
    #expect(NodeMemory.firstPassMarker(projectPath: "/tmp/p", nodeID: node, baseURL: base) == nil)
  }
}
