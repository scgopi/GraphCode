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
        == .artifactorySync(projectPath: "/tmp/x", headlines: false, mark: false, json: false))
    #expect(
      try GraphcodeCommand.parse(["artifactory", "list", "/tmp/x"])
        == .artifactoryList(projectPath: "/tmp/x", search: nil, json: false))
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

// MARK: Read-side verbs (status line, headlines, read, --json, --search, --mark)

private func boardWithPosts() -> (LoopGraph, LoopNode) {
  var graph = LoopGraph(project: ProjectRef(path: "/tmp/x", name: "x"))
  var reader = LoopNode(title: "Reader", loopType: .turnBased)
  reader.lastArtifactoryRead = 1
  graph.nodes.append(reader)
  graph.artifactory = [
    ArtifactoryPost(
      id: 1, at: Date(timeIntervalSince1970: 0), authorID: nil, author: "a human",
      topic: nil, body: "already read"),
    ArtifactoryPost(
      id: 2, at: Date(timeIntervalSince1970: 1), authorID: UUID(), author: "Author",
      topic: "build", body: String(repeating: "red ", count: 40)),
    ArtifactoryPost(
      id: 3, at: Date(timeIntervalSince1970: 2), authorID: nil, author: "a human",
      topic: nil, body: "auth deadlock traced to token refresh"),
  ]
  return (graph, reader)
}

@Test
func syncParsesItsReadModes() throws {
  let plain = try GraphcodeCommand.parse(["artifactory", "sync", "/tmp/x"])
  #expect(
    plain == .artifactorySync(projectPath: "/tmp/x", headlines: false, mark: false, json: false))

  let all = try GraphcodeCommand.parse([
    "artifactory", "sync", "/tmp/x", "--headlines", "--mark", "--json",
  ])
  #expect(
    all == .artifactorySync(projectPath: "/tmp/x", headlines: true, mark: true, json: true))

  #expect {
    try GraphcodeCommand.parse(["artifactory", "sync", "/tmp/x", "--search", "x"])
  } throws: { error in
    error as? GraphcodeCommand.ParseError == .unknownOption("--search")
  }
}

@Test
func readParsesAPostIDAndRejectsNonNumericOnes() throws {
  #expect(
    try GraphcodeCommand.parse(["artifactory", "read", "/tmp/x", "7"])
      == .artifactoryRead(projectPath: "/tmp/x", postID: 7))

  #expect {
    try GraphcodeCommand.parse(["artifactory", "read", "/tmp/x", "seven"])
  } throws: { error in
    error as? GraphcodeCommand.ParseError
      == .invalidValue(argument: "post-id", value: "seven")
  }

  #expect {
    try GraphcodeCommand.parse(["artifactory", "read", "/tmp/x"])
  } throws: { error in
    error as? GraphcodeCommand.ParseError == .missingArgument("post-id")
  }
}

@Test
func listParsesSearchAndJSON() throws {
  #expect(
    try GraphcodeCommand.parse(["artifactory", "list", "/tmp/x", "--search", "auth", "--json"])
      == .artifactoryList(projectPath: "/tmp/x", search: "auth", json: true))
  #expect(
    try GraphcodeCommand.parse(["artifactory", "list", "/tmp/x"])
      == .artifactoryList(projectPath: "/tmp/x", search: nil, json: false))
}

@Test
func headlinesCutBodiesToATriageLine() {
  let (graph, reader) = boardWithPosts()

  let headlines = GraphcodeCommand.renderArtifactory(graph, unreadFor: reader.id, headlines: true)
  #expect(headlines.contains("#2 (build)"))
  #expect(!headlines.contains("red red red red red red red red red red red red"))
  let full = GraphcodeCommand.renderArtifactory(graph, unreadFor: reader.id)
  #expect(full.contains("red red"))
}

@Test
func searchFiltersWhatIsShownButNeverWhatIsRemembered() {
  let (graph, reader) = boardWithPosts()

  // "deadlock" lives only in #3's body — note "auth" would have matched #2's
  // author ("Author"), which is the filter doing its job, not a bug.
  let filtered = GraphcodeCommand.renderArtifactory(graph, unreadFor: reader.id, search: "deadlock")
  #expect(filtered.contains("#3"))
  #expect(!filtered.contains("#2"))

  #expect(
    GraphcodeCommand.renderArtifactory(graph, search: "nonesuch")
      .contains("no posts match 'nonesuch'"))
  #expect(
    GraphcodeCommand.renderArtifactory(graph, unreadFor: reader.id, search: "nonesuch")
      .contains("no unread posts match 'nonesuch'"))
}

@Test
func jsonRendersTheSameTruthInOtherSyntax() throws {
  struct Board: Decodable {
    let posts: [ArtifactoryPost]
    let lastRead: Int?
  }
  let (graph, reader) = boardWithPosts()

  let forReader = try #require(
    GraphcodeCommand.renderArtifactoryJSON(graph, unreadFor: reader.id).data(using: .utf8))
  let decoder = JSONDecoder()
  decoder.dateDecodingStrategy = .iso8601
  let decoded = try decoder.decode(Board.self, from: forReader)
  #expect(decoded.lastRead == 1)
  #expect(decoded.posts.map(\.id) == [2, 3])

  let whole = try #require(
    GraphcodeCommand.renderArtifactoryJSON(graph).data(using: .utf8))
  let everything = try decoder.decode(Board.self, from: whole)
  #expect(everything.posts.count == 3)
  #expect(everything.lastRead == nil)
}

@Test
func statusLineCountsPostsAndUnreadOnlyWhenThereAreAny() {
  let (graph, reader) = boardWithPosts()

  #expect(
    GraphcodeCommand.renderArtifactoryStatusLine(graph, readerID: reader.id)
      == "artifactory: 3 posts, 2 unread for you")
  #expect(
    GraphcodeCommand.renderArtifactoryStatusLine(graph) == "artifactory: 3 posts")
  #expect(
    GraphcodeCommand.renderArtifactoryStatusLine(
      LoopGraph(project: ProjectRef(path: "/tmp/x", name: "x"))) == nil)

  let rendered = GraphcodeCommand.render(graph, artifactoryReader: reader.id)
  #expect(rendered.contains("artifactory: 3 posts, 2 unread for you"))
}

// MARK: Read-side review round (status-line blast radius, json+search, boundaries)

@Test
func statusLineSurvivesAnEmptyNodeGraphWithHumanPosts() {
  var graph = LoopGraph(project: ProjectRef(path: "/tmp/x", name: "x"))
  graph.artifactory = [
    ArtifactoryPost(
      id: 1, at: Date(timeIntervalSince1970: 0), authorID: nil, author: "a human",
      topic: nil, body: "written after the last loop was deleted")
  ]

  let rendered = GraphcodeCommand.render(graph)
  #expect(rendered.contains("no loops yet"))
  #expect(rendered.contains("artifactory: 1 post"))
}

@Test
func neverTouchedBoardRendersExactlyAsBeforeTheArtifactory() {
  var graph = LoopGraph(project: ProjectRef(path: "/tmp/x", name: "x"))
  graph.nodes.append(LoopNode(title: "Solo", loopType: .turnBased, firstInstruction: "Work"))

  let rendered = GraphcodeCommand.render(graph, artifactoryReader: UUID())
  #expect(!rendered.contains("artifactory:"))
  #expect(!rendered.contains("\n  edges:"))
}

@Test
func foreignReaderGetsThePlainCountLikeAHuman() {
  let (graph, _) = boardWithPosts()
  // The daemon refuses sync for a reader absent from this graph; the status line
  // claims no "unread for you" for one either.
  #expect(
    GraphcodeCommand.renderArtifactoryStatusLine(graph, readerID: UUID())
      == "artifactory: 3 posts")
}

@Test
func listJSONHonorsTheSearchFilter() throws {
  struct Board: Decodable {
    let posts: [ArtifactoryPost]
  }
  let (graph, _) = boardWithPosts()

  let filtered = try #require(
    GraphcodeCommand.renderArtifactoryJSON(graph, search: "deadlock").data(using: .utf8))
  let decoder = JSONDecoder()
  decoder.dateDecodingStrategy = .iso8601
  #expect(try decoder.decode(Board.self, from: filtered).posts.map(\.id) == [3])
}

@Test
func jsonDatesAreISOTwo8601NotTheEncoderDefault() throws {
  struct Board: Decodable {
    let posts: [ArtifactoryPost]
  }
  let (graph, _) = boardWithPosts()
  let data = try #require(
    GraphcodeCommand.renderArtifactoryJSON(graph).data(using: .utf8))

  // The pin: decode with the ISO-8601 strategy explicitly. The default (seconds
  // since 2001-01-01) fails here, so nobody can silently change the wire format.
  let decoder = JSONDecoder()
  decoder.dateDecodingStrategy = .iso8601
  let decoded = try decoder.decode(Board.self, from: data)
  #expect(decoded.posts.count == 3)
}

@Test
func headlineTruncatesOnlyPastTheBoundaryAndStaysOneLine() {
  // Rendered prefix up to the body: "#1 from a human at <stamp> — " — build the
  // body so the full line lands exactly at 80, then at 81.
  let at = Date(timeIntervalSince1970: 0)
  let prefix = GraphcodeCommand.render(
    ArtifactoryPost(id: 1, at: at, authorID: nil, author: "a human", topic: nil, body: "")
  )
  let exact = ArtifactoryPost(
    id: 1, at: at, authorID: nil, author: "a human", topic: nil,
    body: String(repeating: "a", count: 80 - prefix.count))
  let over = ArtifactoryPost(
    id: 1, at: at, authorID: nil, author: "a human", topic: nil,
    body: String(repeating: "a", count: 81 - prefix.count))

  #expect(GraphcodeCommand.renderHeadline(exact) == GraphcodeCommand.render(exact))
  #expect(GraphcodeCommand.renderHeadline(over).hasSuffix("…"))
  #expect(!GraphcodeCommand.renderHeadline(over).contains("\n"))
}
