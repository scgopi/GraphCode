import Foundation
import Testing

@testable import GraphcodeKit

/// Seeding Claude Code's folder trust so an unattended session never parks at its
/// first-run "Is this a project you created or one you trust?" dialog — the dialog a
/// fresh unattended `claude` answers by exiting 1, taking the loop's opening pass with
/// it (issue #215). The answer lives only as `projects[<path>].hasTrustDialogAccepted`
/// in `~/.claude.json`, a file Claude Code rewrites constantly, so the seed must be
/// additive and never clobbering.
@Suite
struct ClaudeCodeTrustTests {
  private func temporaryConfig(_ contents: String?) -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent(UUID().uuidString)
      .appendingPathComponent(".claude.json")
    if let contents {
      try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? Data(contents.utf8).write(to: url)
    }
    return url
  }

  @Test
  func aRealConfigGainsTheTrustEntryAndKeepsEverythingElse() throws {
    // The real file holds projects with many keys each, plus top-level state. The seed
    // adds one key to one project and touches nothing else.
    let url = temporaryConfig(
      """
      {"numStartups":9,"projects":{"/tmp/other":{"allowedTools":["Bash"],"hasTrustDialogAccepted":true}},"tipsHistory":{"a":[1]}}
      """)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    ClaudeCodeTrust.ensureTrusted(directory: "/tmp/project", configURL: url)

    let written = try String(contentsOf: url, encoding: .utf8)
    let config = try #require(
      JSONSerialization.jsonObject(with: Data(written.utf8)) as? [String: Any])
    let projects = try #require(config["projects"] as? [String: Any])
    let other = try #require(projects["/tmp/other"] as? [String: Any])
    let seeded = try #require(projects["/tmp/project"] as? [String: Any])
    #expect(other["hasTrustDialogAccepted"] as? Bool == true)
    #expect(seeded["hasTrustDialogAccepted"] as? Bool == true)
    #expect(config["numStartups"] as? Int == 9)
  }

  @Test
  func aMissingConfigIsCreated() throws {
    let url = temporaryConfig(nil)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    ClaudeCodeTrust.ensureTrusted(directory: "/tmp/project", configURL: url)
    let written = try String(contentsOf: url, encoding: .utf8)
    let config = try #require(
      JSONSerialization.jsonObject(with: Data(written.utf8)) as? [String: Any])
    let projects = try #require(config["projects"] as? [String: Any])
    #expect(projects.count == 1)
  }

  /// Additive and idempotent: a directory already trusted changes nothing, so the seed
  /// can run on every launch without churning a file Claude Code is itself rewriting.
  @Test
  func anAlreadyTrustedDirectoryLeavesTheFileUntouched() throws {
    let url = temporaryConfig(
      #"{"projects":{"/tmp/project":{"hasTrustDialogAccepted":true,"allowedTools":[]}}}"#)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let before = try Data(contentsOf: url)
    ClaudeCodeTrust.ensureTrusted(directory: "/tmp/project", configURL: url)
    #expect(try Data(contentsOf: url) == before)
  }

  /// A config it cannot parse is left exactly as found — the dialog is a recoverable
  /// failure, a clobbered `~/.claude.json` (prompt history, per-project state) is not.
  @Test
  func garbageIsLeftExactlyAsFound() throws {
    let url = temporaryConfig("{not json at all")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    ClaudeCodeTrust.ensureTrusted(directory: "/tmp/project", configURL: url)
    #expect(try String(contentsOf: url, encoding: .utf8) == "{not json at all")
  }

  /// A `projects` value the seed does not understand is left exactly as found too:
  /// replacing it with a dictionary would trade the user's real state for a guess.
  @Test
  func anUnexpectedProjectsShapeIsLeftUntouched() throws {
    let url = temporaryConfig(#"{"projects":"unexpected"}"#)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    ClaudeCodeTrust.ensureTrusted(directory: "/tmp/project", configURL: url)
    #expect(try String(contentsOf: url, encoding: .utf8) == #"{"projects":"unexpected"}"#)
  }

  @Test
  func anEmptyDirectoryIsNeverWritten() throws {
    let url = temporaryConfig(#"{"projects":{}}"#)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let before = try Data(contentsOf: url)
    ClaudeCodeTrust.ensureTrusted(directory: "", configURL: url)
    #expect(try Data(contentsOf: url) == before)
  }
}
