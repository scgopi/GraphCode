import Foundation
import Testing

@testable import GraphcodeKit

/// OpenCode as a real backend, spiked against 1.18.21.
///
/// Every flag asserted here was read off the installed `opencode --help`, and every
/// plugin event off a probe plugin run against the real binary, not off the docs. The
/// shape that matters: `opencode` takes its prompt as the value of `--prompt`, resumes
/// with `--session`, and reports through a plugin that arrives in the *environment*
/// (`OPENCODE_CONFIG`) rather than on the argv — the fourth answer to the question
/// `presenceArguments` asks.
@Suite
struct OpenCodeBackendTests {
  private func node(_ loopType: LoopType = .goalBased, tier: ModelTier? = nil) -> LoopNode {
    LoopNode(
      title: "Ship it",
      loopType: loopType,
      goal: GoalSpec(summary: "Tests pass"),
      backend: .openCode,
      modelTier: tier)
  }

  @Test
  func theSessionRunsOpenCodeNotClaude() {
    let arguments = ZmxSessionLauncher.arguments(forNode: node()) ?? []

    // With a plugin to hand over the line is `exec env OPENCODE_CONFIG=… opencode "$@"`,
    // and without one it is bare; either way it ends in the agent.
    #expect(arguments.contains(where: { $0.hasSuffix(#"opencode "$@""#) }))
    #expect(!arguments.contains(where: { $0.contains("claude ") }))
  }

  @Test
  func thePromptRidesBehindItsOwnFlag() {
    // `--prompt <text>` opens the TUI already running the prompt — an attachable
    // session, unlike `opencode run`, which exits when the work is done.
    let arguments = ZmxSessionLauncher.arguments(forNode: node()) ?? []

    let flagIndex = try? #require(arguments.firstIndex(of: "--prompt"))
    #expect(flagIndex != nil)
    if let flagIndex {
      #expect(arguments[flagIndex + 1].contains("Tests pass"))
      #expect(arguments.index(after: flagIndex) == arguments.index(before: arguments.endIndex))
    }
    #expect(!arguments.contains("--interactive"))
  }

  @Test
  func theUnattendedDefaultIsAuto() {
    // `--auto` approves everything the user's own `opencode.json` doesn't deny. Without
    // it OpenCode asks per tool, and an unattended loop sits at that dialog reported as
    // running.
    let arguments = CLISessionBackendKind.openCode.launchArguments(
      prompt: "go", tier: .standard, settings: GraphcodeSettings())
    #expect(arguments.contains("--auto"))

    let asking = CLISessionBackendKind.openCode.launchArguments(
      prompt: "go", tier: .standard, settings: GraphcodeSettings(openCodePermissions: .ask))
    #expect(!asking.contains("--auto"))
  }

  @Test
  func noTierNamesAModelBecauseTheProviderIsTheUsers() {
    // `-m` takes `provider/model`, and which providers are connected is a fact about the
    // user's `opencode auth`, not about a tier. A guessed one fails at launch.
    for tier in ModelTier.allCases {
      #expect(CLISessionBackendKind.openCode.modelArguments(for: tier).isEmpty)
    }
  }

  @Test
  func theBriefingIsAPointerInThePromptAndNeedsNoDirectoryGrant() {
    let arguments = CLISessionBackendKind.openCode.launchArguments(
      prompt: "go", tier: .standard, briefingPath: "/Users/x/.graphcode/briefings/b.md",
      workspacePaths: ["/work"])

    #expect(!arguments.contains("--add-dir"))
    let flagIndex = try? #require(arguments.firstIndex(of: "--prompt"))
    if let flagIndex {
      #expect(arguments[flagIndex + 1].contains("/Users/x/.graphcode/briefings/b.md"))
      #expect(arguments[flagIndex + 1].hasSuffix(" go"))
    }
    #expect(CLISessionBackendKind.openCode.promptFlag == "--prompt")
    #expect(!CLISessionBackendKind.openCode.briefingNeedsDirectoryGrant)
  }

  @Test
  func thePluginArrivesThroughTheEnvironmentNotTheArgv() {
    let hooks = URL(fileURLWithPath: "/Users/x/.graphcode/hooks/openCode.json")

    #expect(
      CLISessionBackendKind.openCode.presenceArguments(hooksFile: hooks, sessionName: "s").isEmpty)
    #expect(
      CLISessionBackendKind.openCode.presenceEnvironment(hooksFile: hooks)
        == ["OPENCODE_CONFIG": hooks.path])
    #expect(CLISessionBackendKind.openCode.presenceEnvironment(hooksFile: nil).isEmpty)
    // Nobody else uses the environment for this.
    #expect(CLISessionBackendKind.claudeCode.presenceEnvironment(hooksFile: hooks).isEmpty)
  }

  @Test
  func resumeUsesSessionNotContinue() {
    // `--continue` would take the *last* session on the machine, which with several
    // loops running is somebody else's conversation.
    #expect(
      CLISessionBackendKind.openCode.resumeArguments(sessionID: "ses_1") == ["--session", "ses_1"])
    #expect(CLISessionBackendKind.openCode.supportsResume)
    #expect(
      CLISessionBackendKind.claudeCode.resumeArguments(sessionID: "abc") == ["--resume", "abc"])
    #expect(CLISessionBackendKind.codex.supportsResume)
    #expect(
      CLISessionBackendKind.codex.resumeArguments(sessionID: "abc") == ["resume", "abc"])
  }

  @Test
  func theConfigNamesOnlyThePlugin() {
    // `OPENCODE_CONFIG` merges over the user's own config, and this must add exactly one
    // thing to it. A config carrying anything else would silently override theirs.
    let json = PresenceHooks.json(forBackend: .openCode, zmxPath: "/usr/local/bin/zmx") ?? ""
    let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]

    #expect(object?.keys.sorted() == ["plugin"])
    #expect((object?["plugin"] as? [String])?.first?.hasSuffix("opencode-presence.js") == true)
  }

  @Test
  func thePluginReportsEveryEdgeTheGraphReads() {
    let source = OpenCodePresencePlugin.source(
      zmxPath: "/Users/o'brien/bin/zmx", sessionsDirectory: "/Users/o'brien/.graphcode/sessions")

    // The paths land as JS string literals, quote and all.
    #expect(source.contains(#"const ZMX = "/Users/o'brien/bin/zmx""#))
    // The same guard every Claude Code hook carries: not a graphcode session, do nothing.
    #expect(source.contains("process.env.ZMX_SESSION"))
    // Both edges of a turn, the tool inside it, and the one state only a plugin can see.
    for event in [
      "session.created", "session.status", "session.idle", "permission.asked",
      "tool.execute.before", "message.updated",
    ] {
      #expect(source.contains(event), "\(event) is not reported")
    }
    for label in ["presence=busy", "presence=idle", "presence=awaitingInput", "usage=input."] {
      #expect(source.contains(label), "\(label) is never written")
    }
    // A sub-agent's session must not blank the loop's card — the `SubagentStop` lesson.
    #expect(source.contains("parentID"))
  }

  @Test
  func aRemoteLaunchWritesAndLoadsItsPresencePlugin() throws {
    let remoteNode = LoopNode(
      title: "Ship it", loopType: .goalBased, goal: GoalSpec(summary: "Tests pass"),
      backend: .openCode, state: .running)
    let location = RemoteProjectLocation(
      user: "dev", host: "build-box", remotePath: "/home/dev/widget")
    let invocation = try #require(
      ZmxSessionLauncher.remoteEnsureInvocation(forNode: remoteNode, at: location))
    let command = try #require(invocation.last)

    #expect(command.contains("opencode-presence.js"))
    #expect(command.contains("OPENCODE_CONFIG"))
    #expect(command.contains("$HOME/.graphcode/hooks/openCode.json"))
    #expect(command.contains("process.env.HOME"))
  }

  @Test
  func itHostsEveryLoopTypeButComposite() {
    #expect(CLISessionBackendKind.openCode.canHost(.goalBased))
    #expect(CLISessionBackendKind.openCode.canHost(.turnBased))
    #expect(CLISessionBackendKind.openCode.canHost(.sketch))
    #expect(CLISessionBackendKind.openCode.canHost(.timeBased))
    #expect(!CLISessionBackendKind.openCode.canHost(.composite))
    #expect(CLISessionBackendKind.offerableAsDefault.contains(.openCode))
  }

  @Test
  func settingsRoundTripAndDefaultToAuto() throws {
    let decoded = try JSONDecoder().decode(GraphcodeSettings.self, from: Data("{}".utf8))
    #expect(decoded.openCodePermissions == .auto)

    var settings = GraphcodeSettings()
    settings.openCodePermissions = .ask
    let data = try JSONEncoder().encode(settings)
    let back = try JSONDecoder().decode(GraphcodeSettings.self, from: data)
    #expect(back.openCodePermissions == .ask)
  }

  @Test
  func theHeadlessInvocationIsRun() {
    #expect(
      SummaryModelWriter.invocation(forBackend: .openCode, prompt: "say hi")
        == ["opencode", "run", "say hi"])
  }
}
