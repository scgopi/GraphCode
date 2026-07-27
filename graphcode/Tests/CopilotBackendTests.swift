import Foundation
import Testing

@testable import GraphcodeKit

/// GitHub Copilot CLI as a real backend, spiked against 0.0.410.
///
/// Every flag asserted here was read off the installed `copilot --help`, not assumed. The
/// point of the suite is that the argv differs from Claude Code's in shape, not just in
/// executable name — `claude` takes its opening prompt positionally, `copilot` takes it
/// as the value of `--interactive`.
@Suite
struct CopilotBackendTests {
  private func node(
    _ loopType: LoopType = .goalBased,
    tier: ModelTier? = nil
  ) -> LoopNode {
    LoopNode(
      title: "Ship it",
      loopType: loopType,
      goal: GoalSpec(summary: "Tests pass"),
      backend: .copilotCLI,
      modelTier: tier)
  }

  @Test
  func theSessionRunsCopilotNotClaude() {
    // The bug this closes: both launch paths hardcoded `claude`, so a node configured
    // for Copilot opened a Claude Code session with nothing on screen to say so.
    let arguments = try? #require(ZmxSessionLauncher.arguments(forNode: node()))

    #expect(arguments?.contains(#"exec copilot "$@""#) == true)
    #expect(arguments?.contains(where: { $0.contains("claude ") }) == false)
  }

  @Test
  func thePromptRidesInOnInteractiveRatherThanPositionally() {
    // `--interactive <prompt>` starts an attachable session that auto-runs the prompt.
    // `-p/--prompt` would exit on completion — the headless shape graphcode moved away
    // from, because nobody can attach to or steer it.
    let arguments = ZmxSessionLauncher.arguments(forNode: node()) ?? []

    let flagIndex = try? #require(arguments.firstIndex(of: "--interactive"))
    #expect(flagIndex != nil)
    if let flagIndex {
      // The prompt is the very next argument — its value, not a separate positional.
      #expect(arguments[flagIndex + 1].contains("Tests pass"))
      #expect(arguments.index(after: flagIndex) == arguments.index(before: arguments.endIndex))
    }
    #expect(!arguments.contains("-p"))
    #expect(!arguments.contains("--prompt"))
  }

  @Test
  func modelTiersMapToCopilotsOwnModelIDs() {
    // Copilot's `--model` takes explicit versioned ids from a fixed set, where Claude
    // Code takes short aliases. Pointing one backend's strings at the other would fail
    // at runtime, which is why the mapping is per-backend.
    #expect(
      CLISessionBackendKind.copilotCLI.modelArguments(for: .fast)
        == ["--model", "claude-haiku-4.5"])
    #expect(
      CLISessionBackendKind.copilotCLI.modelArguments(for: .capable)
        == ["--model", "claude-opus-4.6"])
    // Claude Code's aliases stay aliases — they keep resolving to the current model.
    #expect(CLISessionBackendKind.claudeCode.modelArguments(for: .fast) == ["--model", "haiku"])
  }

  @Test
  func theStandardTierPassesNoModelFlagOnEitherBackend() {
    // No flag lets the backend's own default apply, which is different from asserting
    // what we think it is.
    #expect(CLISessionBackendKind.copilotCLI.modelArguments(for: .standard).isEmpty)
    #expect(CLISessionBackendKind.claudeCode.modelArguments(for: .standard).isEmpty)
  }

  @Test
  func aPinnedTierReachesTheCopilotArgv() {
    let arguments = ZmxSessionLauncher.arguments(forNode: node(tier: .capable)) ?? []

    #expect(arguments.contains("--model"))
    #expect(arguments.contains("claude-opus-4.6"))
  }

  @Test
  func copilotCanHostTurnBasedAndGoalBasedOnly() {
    // Goal-based works because a goal is just a prompt plus a predicate the *daemon*
    // polls from outside — nothing about it needs a skill the agent has to own.
    #expect(CLISessionBackendKind.copilotCLI.canHost(.turnBased))
    #expect(CLISessionBackendKind.copilotCLI.canHost(.goalBased))
    // Time-based does: the cadence lives inside the session as a `/loop` directive, and
    // Copilot has no equivalent, so it would run once and look like a broken schedule.
    #expect(!CLISessionBackendKind.copilotCLI.canHost(.timeBased))
    #expect(!CLISessionBackendKind.copilotCLI.canHost(.proactive))
  }

  @Test
  func copilotCanReceiveMessagesAndReportsNoHooks() {
    let capabilities = CLISessionBackendKind.copilotCLI.capabilities

    // It's a TUI in a PTY, so `zmx send` types into it — it can be a `.message` target.
    #expect(capabilities.supportsMidSessionInput)
    #expect(capabilities.supportsMCP)
    // No lifecycle-hook mechanism in its help, so presence falls back to the heuristic
    // rather than being reported as fact.
    #expect(!capabilities.supportsHooks)
  }

  @Test
  func aCopilotNodeGetsTheRealAdapterNotTheStub() {
    let backend = CLISessionBackend.backend(for: node())
    #expect(backend.kind == .copilotCLI)
    // Codex still gets the honest no-op stub.
    #expect(CLISessionBackendKind.codex.executableName == nil)
  }

  @Test
  func aBackendWithNoExecutableLaunchesNothing() {
    // Belt to `canHost`'s braces: even if such a node existed, no argv is built for it,
    // so nothing is silently started in its place.
    let codexNode = LoopNode(
      title: "Ship", loopType: .goalBased, goal: GoalSpec(summary: "Tests pass"),
      backend: .codex)

    #expect(ZmxSessionLauncher.arguments(forNode: codexNode) == nil)
  }
}
