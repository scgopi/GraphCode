import Foundation
import Testing

@testable import GraphcodeKit

/// The settings a human can change, and the file both the app and the daemon read them
/// from. The daemon is the process that builds a session's launch command, which is why
/// these live in `~/.graphcode/settings.json` rather than in the app's `UserDefaults`.
@Suite
struct GraphcodeSettingsTests {
  private func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("graphcode-settings-\(UUID().uuidString)", isDirectory: true)
      .appendingPathComponent("settings.json")
  }

  @Test
  func theDefaultsAreWhatWasHardcodedBefore() {
    let settings = GraphcodeSettings()
    #expect(settings.defaultBackend == .claudeCode)
    #expect(settings.claudePermissionMode == .auto)
    #expect(settings.copilotPermissions == .allowTools)
    #expect(settings.briefsSessionsAboutTheGraph)
    #expect(settings.windowOpacity == 0.95)
  }

  @Test
  func settingsRoundTripThroughTheFile() {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let settings = GraphcodeSettings(
      defaultBackend: .copilotCLI, claudePermissionMode: .bypassPermissions,
      copilotPermissions: .ask, briefsSessionsAboutTheGraph: false, windowOpacity: 0.8)

    #expect(GraphcodeSettingsStore.save(settings, to: url))
    #expect(GraphcodeSettingsStore.load(from: url) == settings)
  }

  @Test
  func aMissingOrCorruptFileFallsBackToDefaults() throws {
    // Refusing to start sessions because a preferences file didn't parse would be a far
    // worse failure than ignoring it.
    #expect(GraphcodeSettingsStore.load(from: temporaryURL()) == GraphcodeSettings())

    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "{ not json at all".write(to: url, atomically: true, encoding: .utf8)
    #expect(GraphcodeSettingsStore.load(from: url) == GraphcodeSettings())
  }

  @Test
  func aFileFromAnotherVersionKeepsTheKeysItHas() throws {
    // A missing key takes its default rather than failing the whole read — otherwise
    // adding one field would silently revert every other setting.
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try #"{"windowOpacity": 0.7}"#.write(to: url, atomically: true, encoding: .utf8)

    let loaded = GraphcodeSettingsStore.load(from: url)
    #expect(loaded.windowOpacity == 0.7)
    #expect(loaded.claudePermissionMode == .auto)
    #expect(loaded.briefsSessionsAboutTheGraph)
  }

  @Test
  func opacityCannotBeSetLowEnoughToLoseTheWindow() {
    // Including by hand-editing the file — a window you can't see is a window you can't
    // use to fix the setting that hid it.
    #expect(
      GraphcodeSettings(windowOpacity: 0).windowOpacity == GraphcodeSettings.minimumWindowOpacity)
    #expect(
      GraphcodeSettings(windowOpacity: -5).windowOpacity == GraphcodeSettings.minimumWindowOpacity)
    #expect(GraphcodeSettings(windowOpacity: 4).windowOpacity == 1)
  }

  @Test
  func thePermissionSettingIsWhatReachesTheCommandLine() {
    let strict = GraphcodeSettings(claudePermissionMode: .manual, copilotPermissions: .ask)
    let claude = CLISessionBackendKind.claudeCode.launchArguments(
      prompt: "go", tier: .standard, settings: strict)
    #expect(Array(claude.prefix(2)) == ["--permission-mode", "manual"])

    let copilot = CLISessionBackendKind.copilotCLI.launchArguments(
      prompt: "go", tier: .standard, settings: strict)
    #expect(!copilot.contains("--allow-all-tools"))

    let loose = GraphcodeSettings(
      claudePermissionMode: .bypassPermissions, copilotPermissions: .allowEverything)
    #expect(
      CLISessionBackendKind.copilotCLI.launchArguments(
        prompt: "go", tier: .standard, settings: loose
      ).contains("--allow-all"))
  }

  @Test
  func codexIsNotOfferedAsADefaultUntilItIsSpiked() {
    // graphcode can't launch it, so making it the default would set every new loop to
    // something that never starts.
    #expect(!CLISessionBackendKind.offerableAsDefault.contains(.codex))
    #expect(CLISessionBackendKind.offerableAsDefault == [.claudeCode, .copilotCLI])
    // And a file naming it — hand-edited, or written by a build where it was offered —
    // falls back rather than being honoured.
    #expect(GraphcodeSettings(defaultBackend: .codex).defaultBackend == .claudeCode)
    var settings = GraphcodeSettings(defaultBackend: .copilotCLI)
    settings.defaultBackend = .codex
    #expect(settings.defaultBackend == .copilotCLI)
  }

  @Test
  func planModeIsNotOfferedBecauseALoopInItWouldDoNothing() {
    // It's a real CLI mode, deliberately absent: a loop that produces a plan and changes
    // nothing would resolve having done no work.
    #expect(
      !GraphcodeSettings.ClaudePermissionMode.allCases.contains {
        $0.rawValue == "plan"
      })
  }
}
