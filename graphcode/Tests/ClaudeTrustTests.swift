import Foundation
import Testing

@testable import GraphcodeKit

@Suite
struct ClaudeTrustTests {
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
  func trustIsAddedWithoutChangingExistingProjectSettings() throws {
    let url = temporaryConfig(
      #"{"projects":{"/tmp/project":{"allowedTools":["Bash"]}},"theme":"dark"}"#)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    ClaudeTrust.ensureTrusted(directory: "/tmp/project", configURL: url)

    let data = try Data(contentsOf: url)
    let config = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let projects = try #require(config["projects"] as? [String: Any])
    let project = try #require(projects["/tmp/project"] as? [String: Any])
    #expect(project["hasTrustDialogAccepted"] as? Bool == true)
    #expect(project["allowedTools"] as? [String] == ["Bash"])
    #expect(config["theme"] as? String == "dark")
  }

  @Test
  func aMissingConfigIsCreated() throws {
    let url = temporaryConfig(nil)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    ClaudeTrust.ensureTrusted(directory: "/tmp/project", configURL: url)

    #expect(try String(contentsOf: url, encoding: .utf8).contains("hasTrustDialogAccepted"))
  }

  @Test
  func anAlreadyTrustedDirectoryLeavesTheFileUntouched() throws {
    let url = temporaryConfig(
      #"{"projects":{"/tmp/project":{"hasTrustDialogAccepted":true}}}"#)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let before = try Data(contentsOf: url)

    ClaudeTrust.ensureTrusted(directory: "/tmp/project", configURL: url)

    #expect(try Data(contentsOf: url) == before)
  }

  @Test
  func malformedConfigIsLeftUntouched() throws {
    let url = temporaryConfig("{not json")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    ClaudeTrust.ensureTrusted(directory: "/tmp/project", configURL: url)

    #expect(try String(contentsOf: url, encoding: .utf8) == "{not json")
  }

  @Test
  func anUnexpectedProjectsShapeIsLeftUntouched() throws {
    let url = temporaryConfig(#"{"projects":"unexpected"}"#)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    ClaudeTrust.ensureTrusted(directory: "/tmp/project", configURL: url)

    #expect(try String(contentsOf: url, encoding: .utf8) == #"{"projects":"unexpected"}"#)
  }
}
