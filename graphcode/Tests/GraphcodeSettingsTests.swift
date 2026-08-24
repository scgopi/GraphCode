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
    #expect(settings.copilotPermissions == .allowEverything)
    #expect(settings.briefsSessionsAboutTheGraph)
  }

  @Test
  func settingsRoundTripThroughTheFile() {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let settings = GraphcodeSettings(
      defaultBackend: .copilotCLI, claudePermissionMode: .bypassPermissions,
      copilotPermissions: .ask, briefsSessionsAboutTheGraph: false)

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
    // `windowOpacity` is a *retired* key — graphcode used to apply it as
    // `NSWindow.alphaValue` and no longer has the setting at all. Every existing settings
    // file still carries it, so a file that has it must still load rather than throwing
    // and reverting everything else to defaults.
    try #"{"windowOpacity": 0.7, "claudePermissionMode": "dontAsk"}"#
      .write(to: url, atomically: true, encoding: .utf8)

    let loaded = GraphcodeSettingsStore.load(from: url)
    #expect(loaded.claudePermissionMode == .dontAsk)
    #expect(loaded.briefsSessionsAboutTheGraph)
    #expect(loaded.defaultBackend == .claudeCode)
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
    // Emitted as `--yolo` — the same flag as `--allow-all`, under the name Copilot
    // itself promotes.
    #expect(
      CLISessionBackendKind.copilotCLI.launchArguments(
        prompt: "go", tier: .standard, settings: loose
      ).contains("--yolo"))

    // Autopilot rides on top of YOLO's permissions rather than replacing them (issue
    // #86) — both flags have to reach the command line, and the default stays plain
    // `--yolo`.
    let autopilot = GraphcodeSettings(copilotPermissions: .yoloAutopilot)
    let args = CLISessionBackendKind.copilotCLI.launchArguments(
      prompt: "go", tier: .standard, settings: autopilot)
    #expect(args.contains("--yolo") && args.contains("--autopilot"))
    #expect(GraphcodeSettings().copilotPermissions == .allowEverything)
  }

  @Test
  func everySpikedBackendIsOfferedAsADefault() {
    // Codex was withheld while it had no adapter — making it the default would have set
    // every new loop to something that never starts. It has one now (issue #1).
    #expect(
      CLISessionBackendKind.offerableAsDefault == [.claudeCode, .copilotCLI, .codex, .openCode])
    #expect(GraphcodeSettings(defaultBackend: .codex).defaultBackend == .codex)
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
