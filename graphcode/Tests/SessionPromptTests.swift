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
}
