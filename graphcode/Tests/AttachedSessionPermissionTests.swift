import Foundation
import GraphcodeKit
import Testing

@testable import graphcode

/// A node's session can be started by either of two things, and which one wins is a race:
/// `graphcoded` if it got there first, `GhosttyTerminalView` if the node was opened before
/// it did or with `zmx` not installed. They have to agree about how much the session may do
/// without asking, and for a while they didn't — the daemon read the setting and the app
/// didn't pass the flag at all, so a loop opened from the app ran on the CLI's interactive
/// default and sat at the first permission prompt while the graph called it `running`.
///
/// The daemon's half is covered by `GraphcodeSettingsTests`; this is the app's half.
@Suite
struct AttachedSessionPermissionTests {
  private func surface(_ backend: CLISessionBackendKind) -> GhosttyTerminalView {
    GhosttyTerminalView(
      sessionName: "s", launchesClaudeCode: true, backend: backend, initialPrompt: "go",
      workingDirectory: nil, onProcessExited: { _ in })
  }

  /// The command Ghostty runs is a shell string, not an argv array, so the assertions are
  /// against the joined `-c` argument.
  private func shellCommand(
    _ backend: CLISessionBackendKind, _ settings: GraphcodeSettings
  ) -> String {
    surface(backend).agentCommand(settings: settings)?.last ?? ""
  }

  @Test
  func theSettingReachesAnAppStartedSessionForEveryBackend() {
    let settings = GraphcodeSettings(
      codexApprovals: .workspace, claudePermissionMode: .auto, copilotPermissions: .allowTools)

    #expect(shellCommand(.claudeCode, settings).contains("--permission-mode auto"))
    #expect(shellCommand(.copilotCLI, settings).contains("--allow-all-tools"))
    #expect(shellCommand(.codex, settings).contains("--ask-for-approval never"))
    #expect(shellCommand(.codex, settings).contains("--sandbox workspace-write"))
  }

  @Test
  func choosingAStricterModeIsHonouredRatherThanOverridden() {
    // The failure this guards is the tempting fix for the original bug: hardcoding the
    // recommended mode in the app so a loop always starts unattended. That would make the
    // Settings screen a decoration.
    let strict = GraphcodeSettings(
      codexApprovals: .ask, claudePermissionMode: .manual, copilotPermissions: .ask)

    #expect(shellCommand(.claudeCode, strict).contains("--permission-mode manual"))
    #expect(!shellCommand(.claudeCode, strict).contains("auto"))
    // Copilot and Codex spell "ask" as the absence of a flag rather than a value.
    #expect(!shellCommand(.copilotCLI, strict).contains("--allow-all"))
    #expect(!shellCommand(.codex, strict).contains("--ask-for-approval"))
  }

  @Test
  func thePermissionFlagSitsAheadOfThePromptAndBehindTheModel() throws {
    // Order is not cosmetic: `claude` and `codex` take the prompt positionally, so a flag
    // emitted after it would be read as part of the prompt rather than as a flag.
    let command = shellCommand(
      .claudeCode, GraphcodeSettings(claudePermissionMode: .bypassPermissions))
    let permission = try #require(command.range(of: "--permission-mode"))
    let prompt = try #require(command.range(of: "$GRAPHCODE_TRIGGER_PROMPT"))
    #expect(permission.upperBound < prompt.lowerBound)
  }
}
