import ArtifactoryKit
import Foundation
import GraphcodeKit
import Testing

/// The `artifactory` verbs' CLI half: what each spelling parses into and what the board
/// renders as. The daemon half — posting, cursors, watcher wakes — lives in
/// `ArtifactoryTests`; here the question is what a loop or human types and what comes
/// back, because a malformed command must be a useful error, never a quiet no-op.
@Suite
struct ArtifactoryCommandTests {
  // MARK: Parsing

  @Test
  func postJoinsTheNoteAndKeepsTheTopicRaw() throws {
    // Lower-casing is the daemon's job (one spelling per topic across the graph);
    // the CLI carries what was typed.
    #expect(
      try GraphcodeCommand.parse(["artifactory", "post", "/tmp/x", "staking", "issue", "#12"])
        == .artifactoryPost(projectPath: "/tmp/x", topic: nil, text: "staking issue #12"))
    #expect(
      try GraphcodeCommand.parse(
        ["artifactory", "post", "/tmp/x", "--topic", "Claims", "staking", "issue", "#12"])
        == .artifactoryPost(projectPath: "/tmp/x", topic: "Claims", text: "staking issue #12"))
    #expect(
      try GraphcodeCommand.parse(
        ["artifactory", "post", "/tmp/x", "staking", "it", "--topic", "claims"])
        == .artifactoryPost(projectPath: "/tmp/x", topic: "claims", text: "staking it"))
  }

  @Test
  func postWithoutANoteIsAMissingNote() {
    #expect(throws: GraphcodeCommand.ParseError.missingArgument("note")) {
      try GraphcodeCommand.parse(["artifactory", "post", "/tmp/x"])
    }
    // A topic with nothing to say about it is still nothing to post.
    #expect(throws: GraphcodeCommand.ParseError.missingArgument("note")) {
      try GraphcodeCommand.parse(["artifactory", "post", "/tmp/x", "--topic", "build"])
    }
  }

  @Test
  func syncAndListTakeOnlyAProjectPath() throws {
    #expect(
      try GraphcodeCommand.parse(["artifactory", "sync", "/tmp/x"])
        == .artifactorySync(projectPath: "/tmp/x"))
    #expect(
      try GraphcodeCommand.parse(["artifactory", "list", "/tmp/x"])
        == .artifactoryList(projectPath: "/tmp/x"))
  }

  @Test
  func watchDefaultsToEveryPostAndOptsOutWithOff() throws {
    #expect(
      try GraphcodeCommand.parse(["artifactory", "watch", "/tmp/x"])
        == .artifactoryWatch(projectPath: "/tmp/x", on: true, topic: nil))
    #expect(
      try GraphcodeCommand.parse(["artifactory", "watch", "/tmp/x", "--topic", "build"])
        == .artifactoryWatch(projectPath: "/tmp/x", on: true, topic: "build"))
    #expect(
      try GraphcodeCommand.parse(["artifactory", "watch", "/tmp/x", "--off"])
        == .artifactoryWatch(projectPath: "/tmp/x", on: false, topic: nil))
    #expect(
      try GraphcodeCommand.parse(["artifactory", "watch", "/tmp/x", "--topic", "build", "--off"])
        == .artifactoryWatch(projectPath: "/tmp/x", on: false, topic: "build"))
  }

  @Test
  func aMissingProjectPathIsNamedInTheError() {
    #expect(throws: GraphcodeCommand.ParseError.missingArgument("project-path")) {
      try GraphcodeCommand.parse(["artifactory", "post"])
    }
    #expect(throws: GraphcodeCommand.ParseError.missingArgument("project-path")) {
      try GraphcodeCommand.parse(["artifactory", "watch", "--off"])
    }
  }

  @Test
  func unknownArtifactoryVerbAndOptionAreNamed() {
    #expect(throws: GraphcodeCommand.ParseError.unknownCommand("artifactory fetch")) {
      try GraphcodeCommand.parse(["artifactory", "fetch", "/tmp/x"])
    }
    #expect(throws: GraphcodeCommand.ParseError.unknownOption("--filter")) {
      try GraphcodeCommand.parse(["artifactory", "list", "/tmp/x", "--filter", "auth"])
    }
  }

  @Test
  func helpAnywhereInTheVerbPrintsHelpInsteadOfFailing() throws {
    // The one moment a caller admits they don't know the arguments must not be the
    // one moment they are required to supply them — the rule `node create --help`
    // already established.
    #expect(try GraphcodeCommand.parse(["artifactory", "--help"]) == .help)
    #expect(try GraphcodeCommand.parse(["artifactory", "post", "--help"]) == .help)
    #expect(try GraphcodeCommand.parse(["artifactory", "post", "/tmp/x", "-h"]) == .help)
    #expect(try GraphcodeCommand.parse(["artifactory", "sync", "--help"]) == .help)
    #expect(try GraphcodeCommand.parse(["artifactory", "list", "/tmp/x", "--help"]) == .help)
    #expect(try GraphcodeCommand.parse(["artifactory", "watch", "--help"]) == .help)
  }

  // MARK: Rendering

  @Test
  func theBoardRendersOneLinePerPost() {
    var graph = LoopGraph(project: ProjectRef(path: "/tmp/x", name: "x"))
    graph.artifactory = [
      ArtifactoryPost(
        id: 1, at: Date(timeIntervalSince1970: 0), authorID: nil, author: "a human",
        topic: nil, body: "kickoff"),
      ArtifactoryPost(
        id: 4, at: Date(timeIntervalSince1970: 100), authorID: UUID(), author: "Author",
        topic: "claims", body: "issue #12 is mine"),
    ]

    let rendered = GraphcodeCommand.renderArtifactory(graph)

    #expect(rendered.contains("#1 from a human"))
    #expect(rendered.contains("#4 (claims) from Author"))
    #expect(rendered.contains("issue #12 is mine"))
  }

  @Test
  func unreadForReaderUsesItsCursorNotTheCount() {
    var graph = LoopGraph(project: ProjectRef(path: "/tmp/x", name: "x"))
    var reader = LoopNode(title: "Reader", loopType: .turnBased)
    reader.lastArtifactoryRead = 1
    graph.nodes.append(reader)
    graph.artifactory = [
      ArtifactoryPost(
        id: 1, at: Date(timeIntervalSince1970: 0), authorID: nil, author: "a human",
        topic: nil, body: "already read"),
      ArtifactoryPost(
        id: 2, at: Date(timeIntervalSince1970: 1), authorID: nil, author: "a human",
        topic: nil, body: "still unread"),
    ]

    let forReader = GraphcodeCommand.renderArtifactory(graph, unreadFor: reader.id)
    #expect(forReader.contains("#2"))
    #expect(!forReader.contains("#1 "))

    // A loop that never synced sees everything; so does one whose id is not on this
    // graph (no cursor to subtract from).
    #expect(GraphcodeCommand.renderArtifactory(graph, unreadFor: UUID()).contains("#1"))
  }

  @Test
  func emptyBoardAndNothingUnreadSaySo() {
    var graph = LoopGraph(project: ProjectRef(path: "/tmp/x", name: "x"))
    #expect(GraphcodeCommand.renderArtifactory(graph).contains("the board is empty"))

    var reader = LoopNode(title: "Reader", loopType: .turnBased)
    reader.lastArtifactoryRead = 3
    graph.nodes.append(reader)
    graph.artifactory = [
      ArtifactoryPost(
        id: 3, at: Date(timeIntervalSince1970: 0), authorID: nil, author: "a human",
        topic: nil, body: "caught up")
    ]

    #expect(GraphcodeCommand.renderArtifactory(graph, unreadFor: reader.id) == "no unread posts")
  }

  @Test
  func postedNamesTheNewSequence() {
    var graph = LoopGraph(project: ProjectRef(path: "/tmp/x", name: "x"))
    #expect(GraphcodeCommand.renderPosted(graph) == "posted")

    graph.artifactory = [
      ArtifactoryPost(
        id: 7, at: Date(timeIntervalSince1970: 0), authorID: nil, author: "a human",
        topic: "build", body: "build is red")
    ]
    #expect(GraphcodeCommand.renderPosted(graph) == "posted #7 (build)")
  }

  @Test
  func helpTextTeachesTheArtifactoryVerbs() {
    for verb in ["artifactory post", "artifactory sync", "artifactory list", "artifactory watch"] {
      #expect(GraphcodeCommand.helpText.contains(verb))
    }
  }
}
