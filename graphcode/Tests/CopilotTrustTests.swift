import Foundation
import Testing

@testable import GraphcodeKit

/// Seeding Copilot's folder trust so an unattended session never parks at the dialog
/// that swallows its opening prompt and anything typed after it.
@Suite
struct CopilotTrustTests {
  private func temporaryConfig(_ contents: String?) -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent(UUID().uuidString)
      .appendingPathComponent("config.json")
    if let contents {
      try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? Data(contents.utf8).write(to: url)
    }
    return url
  }

  /// The detail the remote seed missed for as long as it existed: real config files open
  /// with `// …` lines Copilot writes above the JSON, and a plain parse fails on them.
  @Test
  func aRealConfigWithCommentHeaderIsParsedAndTheHeaderKept() throws {
    let url = temporaryConfig(
      """
      // User settings belong in settings.json.
      // This file is managed automatically.
      {"firstLaunchAt":"2026-07-28","trustedFolders":["/tmp/existing"]}
      """)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    CopilotTrust.ensureTrusted(directory: "/tmp/project", configURL: url)

    let written = try String(contentsOf: url, encoding: .utf8)
    #expect(written.hasPrefix("// User settings belong in settings.json."))
    #expect(written.contains("/tmp/existing"))
    #expect(written.contains("/tmp/project"))
    // The unrelated key survives the rewrite.
    #expect(written.contains("firstLaunchAt"))
  }

  @Test
  func aMissingConfigIsCreated() throws {
    let url = temporaryConfig(nil)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    CopilotTrust.ensureTrusted(directory: "/tmp/project", configURL: url)
    #expect(try String(contentsOf: url, encoding: .utf8).contains("/tmp/project"))
  }

  /// Additive and idempotent: a directory already trusted changes nothing, so the seed
  /// can run on every launch without churning the file.
  @Test
  func anAlreadyTrustedDirectoryLeavesTheFileUntouched() throws {
    let url = temporaryConfig(#"{"trustedFolders":["/tmp/project"]}"#)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let before = try Data(contentsOf: url)
    CopilotTrust.ensureTrusted(directory: "/tmp/project", configURL: url)
    #expect(try Data(contentsOf: url) == before)
  }

  /// A config it cannot parse is left exactly as found — the dialog is a recoverable
  /// failure, a clobbered Copilot config is not.
  @Test
  func garbageIsLeftExactlyAsFound() throws {
    let url = temporaryConfig("{not json at all")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    CopilotTrust.ensureTrusted(directory: "/tmp/project", configURL: url)
    #expect(try String(contentsOf: url, encoding: .utf8) == "{not json at all")
  }
}
