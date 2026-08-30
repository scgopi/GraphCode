import Foundation
import GraphcodeKit
import Testing

@testable import graphcode

/// An app-started session gets the same graph briefing a daemon-started one does.
///
/// The gap this closes: `ZmxSessionLauncher` delivered the briefing for every backend,
/// but `GhosttyTerminalView` — the *only* launcher a turn-based loop ever has, since it
/// doesn't start unattended — delivered nothing. A turn-based Copilot loop asked to fan
/// work out had never heard of `graphcode node create` and improvised with its own
/// sub-agents instead.
@Suite
struct AttachedSessionBriefingTests {
  private let briefing = "/tmp/briefings/proj/AGENTS.md"

  private func surface(
    _ backend: CLISessionBackendKind, launchesClaudeCode: Bool = true,
    initialPrompt: String? = "go", loopType: LoopType = .turnBased
  ) -> GhosttyTerminalView {
    GhosttyTerminalView(
      surfaceID: UUID(), sessionName: "s", launchesClaudeCode: launchesClaudeCode,
      backend: backend, loopType: loopType, initialPrompt: initialPrompt, workingDirectory: nil,
      projectPath: "/tmp/proj", onProcessExited: { _ in })
  }

  private func shellCommand(_ backend: CLISessionBackendKind) -> String {
    surface(backend).agentCommand(settings: GraphcodeSettings(), briefingPath: briefing)?
      .last ?? ""
  }

  @Test
  func claudeTakesTheBriefingAsASystemPromptFile() {
    #expect(shellCommand(.claudeCode).contains("--append-system-prompt-file \(briefing)"))
    // And its prompt is not the delivery mechanism, so it stays untouched.
    let environment = surface(.claudeCode).sessionEnvironment(briefingPath: briefing)
    #expect(environment["GRAPHCODE_TRIGGER_PROMPT"] == "go")
  }

  @Test
  func copilotIsGrantedTheDirectoryAndPointedAtTheFile() {
    let command = shellCommand(.copilotCLI)
    // `--add-dir` is the half that is easy to miss: Copilot verifies paths, so without
    // it the pointer reads as the agent ignoring an instruction (issue #2's shape).
    #expect(command.contains("--add-dir /tmp/briefings/proj"))
    #expect(command.contains("--interactive"))

    // The pointer rides inside the env var, where prose needs no shell quoting.
    let environment = surface(.copilotCLI).sessionEnvironment(briefingPath: briefing)
    let prompt = environment["GRAPHCODE_TRIGGER_PROMPT"] ?? ""
    #expect(prompt.contains(briefing))
    #expect(prompt.hasSuffix(" go"))
  }

  @Test
  func codexRidesTheSameWayCopilotDoes() {
    #expect(shellCommand(.codex).contains("--add-dir /tmp/briefings/proj"))
    let prompt =
      surface(.codex).sessionEnvironment(briefingPath: briefing)[
        "GRAPHCODE_TRIGGER_PROMPT"] ?? ""
    #expect(prompt.contains(briefing))
  }

  @Test
  func unattendedCodexLeavesFirstLaunchToTheDaemon() {
    #expect(surface(.codex, loopType: .goalBased).defersCodexLaunchToDaemon)
    #expect(surface(.codex, loopType: .timeBased).defersCodexLaunchToDaemon)
    #expect(!surface(.codex).defersCodexLaunchToDaemon)
    #expect(!surface(.claudeCode, loopType: .goalBased).defersCodexLaunchToDaemon)
  }

  @Test
  func unattendedCodexDoesNotResumeFromTheApp() {
    guard ZmxLocator.isInstalled else { return }
    let view = surface(.codex, loopType: .goalBased)
    let command = view.command(briefingPath: briefing)
    #expect(command.first == "/bin/zsh")
    #expect(command.contains { $0.contains("until") && $0.contains("cmd=.*codex") })
    #expect(command.last?.contains("exec") == true)
    #expect(command.last?.contains("attach 's'") == true)
  }

  @Test
  func noBriefingMeansTheCommandAndPromptOfBefore() {
    let command =
      surface(.copilotCLI).agentCommand(
        settings: GraphcodeSettings(), briefingPath: nil)?.last ?? ""
    #expect(!command.contains("--add-dir"))
    let environment = surface(.copilotCLI).sessionEnvironment(briefingPath: nil)
    #expect(environment["GRAPHCODE_TRIGGER_PROMPT"] == "go")
  }

  @Test
  func surfacesThatShouldNotBeBriefedGetNoFile() {
    // A plain shell is not a loop; a surface with no opening prompt has nothing to hang
    // the pointer on; and the human can switch briefing off entirely.
    let disabled = GraphcodeSettings(briefsSessionsAboutTheGraph: false)
    #expect(surface(.claudeCode, launchesClaudeCode: false).briefingFile() == nil)
    #expect(surface(.copilotCLI, initialPrompt: nil).briefingFile() == nil)
    #expect(surface(.copilotCLI).briefingFile(settings: disabled) == nil)
  }
}
