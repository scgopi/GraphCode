import Foundation
import GraphcodeKit
import Testing

/// `graphcode projects` and `graphcode workspaces`: the CLI's ways to find what every
/// other verb addresses — project paths, and the support directories
/// `GRAPHCODE_SUPPORT_DIR` can point those verbs at. `--json` is for tools that
/// enumerate both.
@Suite
struct GraphcodeListingCommandTests {
  @Test
  func workspacesTakesOnlyJSON() throws {
    #expect(try GraphcodeCommand.parse(["workspaces"]) == .listWorkspaces(json: false))
    #expect(try GraphcodeCommand.parse(["workspaces", "--json"]) == .listWorkspaces(json: true))
    #expect(throws: GraphcodeCommand.ParseError.unknownOption("--yaml")) {
      try GraphcodeCommand.parse(["workspaces", "--yaml"])
    }
  }

  @Test
  func projectsTakesOnlyJSON() throws {
    #expect(try GraphcodeCommand.parse(["projects"]) == .listProjects(json: false))
    #expect(try GraphcodeCommand.parse(["projects", "--json"]) == .listProjects(json: true))
    #expect(throws: GraphcodeCommand.ParseError.unknownOption("--jsn")) {
      try GraphcodeCommand.parse(["projects", "--jsn"])
    }
  }

  @Test
  func askingEitherListForHelpShowsHelp() throws {
    #expect(try GraphcodeCommand.parse(["workspaces", "--help"]) == .help)
    #expect(try GraphcodeCommand.parse(["workspaces", "-h"]) == .help)
    #expect(try GraphcodeCommand.parse(["projects", "--help"]) == .help)
    #expect(try GraphcodeCommand.parse(["projects", "-h"]) == .help)
  }

  @Test
  func eachWorkspacePrintsItsNameAndPathWithTheCurrentOneMarked() {
    let (main, work) = Self.workspaces
    #expect(
      GraphcodeCommand.render([main, work], current: work)
        == "  Default  /Users/me/.graphcode\n* work  /Users/me/.graphcode-work")
  }

  @Test
  func workspacesAsJSONCarryNamePathAndWhichIsCurrent() throws {
    struct Row: Decodable, Equatable {
      var name: String
      var path: String
      var current: Bool
    }
    let (main, work) = Self.workspaces
    let json = GraphcodeCommand.renderJSON([main, work], current: work)
    #expect(
      try JSONDecoder().decode([Row].self, from: Data(json.utf8)) == [
        Row(name: "Default", path: "/Users/me/.graphcode", current: false),
        Row(name: "work", path: "/Users/me/.graphcode-work", current: true),
      ])
  }

  @Test
  func projectsAsJSONCarryNamePathAndLastOpened() throws {
    let project = ProjectRef(
      path: "/Users/me/src/app", name: "app", lastOpenedAt: Date(timeIntervalSince1970: 0))
    let json = GraphcodeCommand.renderJSON([project])
    let rows = try #require(
      try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: String]])
    #expect(
      rows == [
        ["name": "app", "path": "/Users/me/src/app", "lastOpenedAt": "1970-01-01T00:00:00Z"]
      ])
  }

  /// "no projects yet" is for a person; a tool needs an array it can iterate.
  @Test
  func noProjectsAsJSONIsAnEmptyArray() {
    #expect(GraphcodeCommand.renderJSON([ProjectRef]()) == "[]")
  }

  @Test
  func theHelpNamesBothListsAndTheirJSON() {
    #expect(GraphcodeCommand.helpText.contains("graphcode projects [--json]"))
    #expect(GraphcodeCommand.helpText.contains("graphcode workspaces [--json]"))
  }

  private static var workspaces: (Workspace, Workspace) {
    let home = URL(fileURLWithPath: "/Users/me", isDirectory: true)
    return (
      Workspace(slug: "", url: home.appendingPathComponent(".graphcode")),
      Workspace(slug: "work", url: home.appendingPathComponent(".graphcode-work"))
    )
  }
}
