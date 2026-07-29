import Foundation
import GraphcodeKit
import Testing

@testable import graphcode

/// Issue #10: a loop created in the app never sets `modelTier`, and graphcode was routing
/// every one of those by loop type — so a turn-based loop silently ran on `--model opus`
/// and a time-based one on `--model haiku`, overriding whatever model the human had
/// configured in `claude`/`copilot` themselves.
///
/// The distinction being protected here is between *nobody chose* and *someone chose*.
/// Only the first is graphcode's to stop guessing at; a pinned tier still has to win, or
/// the fix would quietly break the CLI's `--model` flag and the composite spawn path that
/// carries a tier from template to instance.
@Suite
struct ModelAutoSelectionTests {
  private func node(_ type: LoopType, pinned: ModelTier? = nil) -> LoopNode {
    LoopNode(
      title: "Loop", loopType: type, triggerPrompt: "/loop 1h Check", modelTier: pinned)
  }

  // MARK: - The default: no model flag at all

  @Test("An unpinned loop passes no model when auto-selection is off")
  func unpinnedPassesNothingByDefault() {
    for type in LoopType.allCases {
      let tier = node(type).effectiveModelTier(autoSelecting: false)
      #expect(tier == .standard, "\(type) should not be routed")
      for backend in CLISessionBackendKind.allCases {
        #expect(
          backend.modelArguments(for: tier).isEmpty,
          "\(backend) should get no --model for an unrouted \(type)")
      }
    }
  }

  /// The default has to be off in the *type's* own default, not merely in the settings
  /// screen — the daemon builds launch commands from a decoded settings file.
  @Test("Auto-selection is off in a default GraphcodeSettings")
  func defaultSettingsDoNotAutoSelect() {
    #expect(!GraphcodeSettings().autoSelectsModel)
  }

  /// A settings file written before this setting existed must land on the new default
  /// rather than keeping the old routing — otherwise the fix reaches only new installs.
  @Test("A settings file with no such key decodes to off")
  func absentKeyDecodesToOff() throws {
    let json = Data(#"{"claudePermissionMode":"auto"}"#.utf8)
    let decoded = try JSONDecoder().decode(GraphcodeSettings.self, from: json)
    #expect(!decoded.autoSelectsModel)
    // And the rest of the file still round-trips, so this didn't break tolerant decoding.
    #expect(decoded.claudePermissionMode == .auto)
  }

  @Test("Turning it on restores routing by loop type")
  func onRoutesByLoopType() {
    #expect(node(.turnBased).effectiveModelTier(autoSelecting: true) == .capable)
    #expect(node(.timeBased).effectiveModelTier(autoSelecting: true) == .fast)
    #expect(node(.goalBased).effectiveModelTier(autoSelecting: true) == .standard)
  }

  // MARK: - A pin still wins

  @Test("A pinned tier is honoured whether auto-selection is on or off")
  func pinnedAlwaysWins() {
    for autoSelecting in [true, false] {
      let tier = node(.timeBased, pinned: .capable)
        .effectiveModelTier(autoSelecting: autoSelecting)
      #expect(tier == .capable)
      #expect(CLISessionBackendKind.claudeCode.modelArguments(for: tier) == ["--model", "opus"])
    }
  }

  /// Pinning `.standard` explicitly and simply not choosing both end up passing no flag.
  /// That is intended — `.standard` means "no opinion" — but it's worth stating, because
  /// it's the one case where the pin is indistinguishable from its absence.
  @Test("An explicit standard pin passes no flag, same as no pin")
  func explicitStandardIsStillNoFlag() {
    let tier = node(.turnBased, pinned: .standard).effectiveModelTier(autoSelecting: true)
    #expect(CLISessionBackendKind.claudeCode.modelArguments(for: tier).isEmpty)
  }

  // MARK: - What the attached session actually runs

  /// `GhosttyTerminalView` builds its own shell string rather than going through
  /// `launchArguments`, so it needs its own assertion — this is exactly the split that let
  /// the permission flag go missing from app-launched sessions.
  @Test("An attached session gets no --model unless auto-selection is on")
  func attachedSessionHonoursTheSetting() throws {
    func command(autoSelecting: Bool, pinned: ModelTier?) -> String {
      let view = GhosttyTerminalView(
        sessionName: "s", launchesClaudeCode: true, backend: .claudeCode,
        pinnedModelTier: pinned, loopType: .turnBased, initialPrompt: nil,
        workingDirectory: nil, onProcessExited: { _ in })
      let settings = GraphcodeSettings(autoSelectsModel: autoSelecting)
      return view.agentCommand(settings: settings)?.last ?? ""
    }

    #expect(!command(autoSelecting: false, pinned: nil).contains("--model"))
    // On, a turn-based loop routes to the capable tier — the old unconditional behaviour,
    // now only when asked for.
    #expect(command(autoSelecting: true, pinned: nil).contains("--model opus"))
    // And a pin reaches the shell regardless of the setting.
    #expect(command(autoSelecting: false, pinned: .fast).contains("--model haiku"))
  }
}
