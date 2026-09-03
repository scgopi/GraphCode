import GraphcodeKit
import Testing

@testable import graphcode

/// What the agent tab in a loop's tab strip is called.
///
/// A rule rather than a view: the strip is what tells you at a glance whether a session
/// is running its own cadence, working to a stop condition, or just sitting at a prompt —
/// and, for that last case, which CLI is sitting there. It named Claude Code whatever the
/// loop had actually chosen (#255), which is exactly the kind of thing no pixel test
/// would have caught.
@Suite
struct AgentTabTitleTests {
  private func title(
    _ loopType: LoopType, _ backend: CLISessionBackendKind = .claudeCode, agent: Bool = true
  ) -> String {
    LoopWorkspaceView.agentTabTitle(loopType: loopType, backend: backend, launchesAgent: agent)
  }

  @Test
  func anAttendedLoopNamesItsBackend() {
    #expect(title(.sketch, .copilotCLI) == "Copilot CLI")
    #expect(title(.turnBased, .codex) == "Codex")
    #expect(title(.composite, .openCode) == "OpenCode")
    #expect(title(.sketch, .claudeCode) == "Claude Code")
  }

  @Test
  func anUnattendedLoopNamesWhatItIsDoingInstead() {
    for backend in CLISessionBackendKind.allCases {
      #expect(title(.timeBased, backend) == "Loop")
      #expect(title(.goalBased, backend) == "Goal")
    }
  }

  @Test
  func aPlainShellPaneIsNeverNamedForABackend() {
    for loopType in LoopType.allCases {
      #expect(title(loopType, .copilotCLI, agent: false) == "Shell")
    }
  }
}
