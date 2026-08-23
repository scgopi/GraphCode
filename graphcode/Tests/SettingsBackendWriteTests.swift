import Foundation
import Testing

@testable import GraphcodeKit

/// Writing the default backend straight to a workspace's settings file.
///
/// The new-workspace starter asks which agent runs this workspace's loops moments after
/// its window opens, and the write used to go through the app's live `SettingsModel` — a
/// singleton whose first touch in a fresh instance was that very effect. Six workspaces
/// were created with the starter answered and not one `settings.json` was written, so the
/// write goes to the file directly now and the live model is synced from it afterwards.
@Suite
struct SettingsBackendWriteTests {
  private func makeSettingsURL() -> URL {
    let directory = URL(fileURLWithPath: "/tmp")
      .appendingPathComponent("gcset-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("settings.json")
  }

  @Test
  func thePickLandsOnAWorkspaceThatHasNoSettingsFileYet() throws {
    // Which is every new workspace: it is made by `createDirectory` and nothing else.
    let url = makeSettingsURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    #expect(!FileManager.default.fileExists(atPath: url.path))
    #expect(GraphcodeSettingsStore.setDefaultBackend(.codex, to: url))
    #expect(FileManager.default.fileExists(atPath: url.path))
    #expect(GraphcodeSettingsStore.load(from: url).defaultBackend == .codex)
  }

  @Test
  func everyBackendSurvivesTheRoundTrip() throws {
    // Copilot and Codex are the two that were reported as not sticking; claudeCode is
    // here so a coercion that quietly forced the default could not pass.
    for backend in CLISessionBackendKind.allCases {
      let url = makeSettingsURL()
      defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

      GraphcodeSettingsStore.setDefaultBackend(backend, to: url)
      #expect(GraphcodeSettingsStore.load(from: url).defaultBackend == backend)
    }
  }

  @Test
  func changingTheBackendLeavesEverySettingBesideItAlone() throws {
    // It reads, changes one field and writes the whole file back, so anything already in
    // there — a permission mode, a worktree policy — has to come through untouched.
    let url = makeSettingsURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    var settings = GraphcodeSettings()
    settings.sharesLoops = true
    settings.showsActivityStrip = false
    GraphcodeSettingsStore.save(settings, to: url)

    GraphcodeSettingsStore.setDefaultBackend(.copilotCLI, to: url)

    let reloaded = GraphcodeSettingsStore.load(from: url)
    #expect(reloaded.defaultBackend == .copilotCLI)
    #expect(reloaded.sharesLoops)
    #expect(!reloaded.showsActivityStrip)
  }

  @Test
  func aSecondPickReplacesTheFirst() throws {
    // The starter applies on every tap, not on the button, so someone trying all three
    // rows must end on the one they left selected.
    let url = makeSettingsURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    GraphcodeSettingsStore.setDefaultBackend(.codex, to: url)
    GraphcodeSettingsStore.setDefaultBackend(.copilotCLI, to: url)
    #expect(GraphcodeSettingsStore.load(from: url).defaultBackend == .copilotCLI)
  }
}
