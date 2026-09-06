import Foundation
import GraphcodeKit
import MailroomKit
import Testing

/// The `mailroom` verbs' CLI half: what each spelling parses into and what the board
/// renders as. The daemon half — posting, cursors, watcher wakes — lives in
/// `MailroomTests`; here the question is what a loop or human types and what comes
/// back, because a malformed command must be a useful error, never a quiet no-op.
@Suite
struct MailroomCommandTests {
  // MARK: Parsing

  @Test
  func postJoinsTheNoteAndKeepsTheTopicRaw() throws {
    // Lower-casing is the daemon's job (one spelling per topic across the graph);
    // the CLI carries what was typed.
    #expect(
      try GraphcodeCommand.parse(["mailroom", "post", "/tmp/x", "staking", "issue", "#12"])
        == .mailroomPost(projectPath: "/tmp/x", topic: nil, text: "staking issue #12"))
    #expect(
      try GraphcodeCommand.parse(
        ["mailroom", "post", "/tmp/x", "--topic", "Claims", "staking", "issue", "#12"])
        == .mailroomPost(projectPath: "/tmp/x", topic: "Claims", text: "staking issue #12"))
    #expect(
      try GraphcodeCommand.parse(
        ["mailroom", "post", "/tmp/x", "staking", "it", "--topic", "claims"])
        == .mailroomPost(projectPath: "/tmp/x", topic: "claims", text: "staking it"))
  }

  @Test
  func postWithoutANoteIsAMissingNote() {
    #expect(throws: GraphcodeCommand.ParseError.missingArgument("note")) {
      try GraphcodeCommand.parse(["mailroom", "post", "/tmp/x"])
    }
    // A topic with nothing to say about it is still nothing to post.
    #expect(throws: GraphcodeCommand.ParseError.missingArgument("note")) {
      try GraphcodeCommand.parse(["mailroom", "post", "/tmp/x", "--topic", "build"])
    }
  }

  @Test
  func syncAndListTakeOnlyAProjectPath() throws {
    #expect(
      try GraphcodeCommand.parse(["mailroom", "sync", "/tmp/x"])
        == .mailroomInbox(
          projectPath: "/tmp/x", headlines: false, mark: false, json: false, full: false))
    #expect(
      try GraphcodeCommand.parse(["mailroom", "list", "/tmp/x"])
        == .mailroomList(projectPath: "/tmp/x", search: nil, json: false))
  }

  @Test
  func watchDefaultsToEveryPostAndOptsOutWithOff() throws {
    #expect(
      try GraphcodeCommand.parse(["mailroom", "watch", "/tmp/x"])
        == .mailroomWatch(projectPath: "/tmp/x", on: true, topic: nil))
    #expect(
      try GraphcodeCommand.parse(["mailroom", "watch", "/tmp/x", "--topic", "build"])
        == .mailroomWatch(projectPath: "/tmp/x", on: true, topic: "build"))
    #expect(
      try GraphcodeCommand.parse(["mailroom", "watch", "/tmp/x", "--off"])
        == .mailroomWatch(projectPath: "/tmp/x", on: false, topic: nil))
    #expect(
      try GraphcodeCommand.parse(["mailroom", "watch", "/tmp/x", "--topic", "build", "--off"])
        == .mailroomWatch(projectPath: "/tmp/x", on: false, topic: "build"))
  }

  @Test
  func aMissingProjectPathIsNamedInTheError() {
    #expect(throws: GraphcodeCommand.ParseError.missingArgument("project-path")) {
      try GraphcodeCommand.parse(["mailroom", "post"])
    }
    #expect(throws: GraphcodeCommand.ParseError.missingArgument("project-path")) {
      try GraphcodeCommand.parse(["mailroom", "watch", "--off"])
    }
  }

  @Test
  func unknownMailroomVerbAndOptionAreNamed() {
    #expect(throws: GraphcodeCommand.ParseError.unknownCommand("mailroom fetch")) {
      try GraphcodeCommand.parse(["mailroom", "fetch", "/tmp/x"])
    }
    #expect(throws: GraphcodeCommand.ParseError.unknownOption("--filter")) {
      try GraphcodeCommand.parse(["mailroom", "list", "/tmp/x", "--filter", "auth"])
    }
  }

  @Test
  func helpAnywhereInTheVerbPrintsHelpInsteadOfFailing() throws {
    // The one moment a caller admits they don't know the arguments must not be the
    // one moment they are required to supply them — the rule `node create --help`
    // already established.
    #expect(try GraphcodeCommand.parse(["mailroom", "--help"]) == .help)
    #expect(try GraphcodeCommand.parse(["mailroom", "post", "--help"]) == .help)
    #expect(try GraphcodeCommand.parse(["mailroom", "post", "/tmp/x", "-h"]) == .help)
    #expect(try GraphcodeCommand.parse(["mailroom", "sync", "--help"]) == .help)
    #expect(try GraphcodeCommand.parse(["mailroom", "list", "/tmp/x", "--help"]) == .help)
    #expect(try GraphcodeCommand.parse(["mailroom", "watch", "--help"]) == .help)
  }

  // MARK: Rendering

  @Test
  func theBoardRendersOneLinePerPost() {
    var graph = LoopGraph(project: ProjectRef(path: "/tmp/x", name: "x"))
    graph.mailroom = [
      MailroomPost(
        id: 1, at: Date(timeIntervalSince1970: 0), authorID: nil, author: "a human",
        topic: nil, body: "kickoff"),
      MailroomPost(
        id: 4, at: Date(timeIntervalSince1970: 100), authorID: UUID(), author: "Author",
        topic: "claims", body: "issue #12 is mine"),
    ]

    let rendered = GraphcodeCommand.renderMailroom(
      Mailroom.serve(
        MailboxQuery(selection: .board, fullBodies: true), from: graph.mailroom
      ) { _ in nil },
      project: graph.project, unread: false)

    #expect(rendered.contains("#1 from a human"))
    #expect(rendered.contains("#4 (claims) from Author"))
    #expect(rendered.contains("issue #12 is mine"))
  }

  @Test
  func unreadForReaderUsesItsCursorNotTheCount() {
    var graph = LoopGraph(project: ProjectRef(path: "/tmp/x", name: "x"))
    var reader = LoopNode(title: "Reader", loopType: .turnBased)
    reader.lastMailroomRead = 1
    graph.nodes.append(reader)
    graph.mailroom = [
      MailroomPost(
        id: 1, at: Date(timeIntervalSince1970: 0), authorID: nil, author: "a human",
        topic: nil, body: "already read"),
      MailroomPost(
        id: 2, at: Date(timeIntervalSince1970: 1), authorID: nil, author: "a human",
        topic: nil, body: "still unread"),
    ]

    let forReader = GraphcodeCommand.renderMailroom(
      served(graph, .unread(reader: reader.id)), project: graph.project, unread: true)
    #expect(forReader.contains("#2"))
    #expect(!forReader.contains("#1 "))

    // A loop that never synced sees everything; so does one whose id is not on this
    // graph (no cursor to subtract from).
    #expect(
      GraphcodeCommand.renderMailroom(
        served(graph, .unread(reader: UUID())), project: graph.project, unread: true
      ).contains("#1"))
  }

  @Test
  func emptyBoardAndNothingUnreadSaySo() {
    var graph = LoopGraph(project: ProjectRef(path: "/tmp/x", name: "x"))
    #expect(
      GraphcodeCommand.renderMailroom(served(graph, .board), project: graph.project, unread: false)
        .contains("the room is empty"))

    var reader = LoopNode(title: "Reader", loopType: .turnBased)
    reader.lastMailroomRead = 3
    graph.nodes.append(reader)
    graph.mailroom = [
      MailroomPost(
        id: 3, at: Date(timeIntervalSince1970: 0), authorID: nil, author: "a human",
        topic: nil, body: "caught up")
    ]

    #expect(
      GraphcodeCommand.renderMailroom(
        served(graph, .unread(reader: reader.id)), project: graph.project, unread: true)
        == "no unread posts")
  }

  @Test
  func postedNamesTheNewSequence() {
    var graph = LoopGraph(project: ProjectRef(path: "/tmp/x", name: "x"))
    #expect(GraphcodeCommand.renderPosted(graph) == "posted")

    graph.mailroom = [
      MailroomPost(
        id: 7, at: Date(timeIntervalSince1970: 0), authorID: nil, author: "a human",
        topic: "build", body: "build is red")
    ]
    // The topic is the caller's, spelled the way the daemon keeps it — the post itself
    // is not on the graph that comes back, only the room's digest is.
    #expect(GraphcodeCommand.renderPosted(graph, topic: " Build ") == "posted #7 (build)")
    #expect(
      GraphcodeCommand.renderPosted(graph.wireSnapshot(), topic: "build") == "posted #7 (build)")
    #expect(GraphcodeCommand.renderPosted(graph.wireSnapshot(), topic: "  ") == "posted #7")
    #expect(GraphcodeCommand.renderPosted(graph) == "posted #7")
  }

  @Test
  func helpTextTeachesTheMailroomVerbs() {
    for verb in ["mail post", "mail inbox", "mail list", "mail watch"] {
      #expect(GraphcodeCommand.helpText.contains(verb))
    }
  }
}

// MARK: Read-side verbs (status line, headlines, read, --json, --search, --mark)

/// The room's answer, served off a graph the way `GraphStore.mailbox` serves it —
/// what every renderer below now takes instead of the graph.
private func served(
  _ graph: LoopGraph, _ selection: MailboxQuery.Selection, search: String? = nil,
  fullBodies: Bool? = nil
) -> Mailbox {
  Mailroom.serve(
    MailboxQuery(selection: selection, search: search, fullBodies: fullBodies),
    from: graph.mailroom
  ) { graph.nodes[id: $0]?.lastMailroomRead }
}

private func boardWithPosts() -> (LoopGraph, LoopNode) {
  var graph = LoopGraph(project: ProjectRef(path: "/tmp/x", name: "x"))
  var reader = LoopNode(title: "Reader", loopType: .turnBased)
  reader.lastMailroomRead = 1
  graph.nodes.append(reader)
  graph.mailroom = [
    MailroomPost(
      id: 1, at: Date(timeIntervalSince1970: 0), authorID: nil, author: "a human",
      topic: nil, body: "already read"),
    MailroomPost(
      id: 2, at: Date(timeIntervalSince1970: 1), authorID: UUID(), author: "Author",
      topic: "build", body: String(repeating: "red ", count: 40)),
    MailroomPost(
      id: 3, at: Date(timeIntervalSince1970: 2), authorID: nil, author: "a human",
      topic: nil, body: "auth deadlock traced to token refresh"),
  ]
  return (graph, reader)
}

@Test
func syncParsesItsReadModes() throws {
  let plain = try GraphcodeCommand.parse(["mailroom", "sync", "/tmp/x"])
  #expect(
    plain
      == .mailroomInbox(
        projectPath: "/tmp/x", headlines: false, mark: false, json: false, full: false))

  let all = try GraphcodeCommand.parse([
    "mailroom", "sync", "/tmp/x", "--headlines", "--mark", "--json",
  ])
  #expect(
    all
      == .mailroomInbox(
        projectPath: "/tmp/x", headlines: true, mark: true, json: true, full: false))

  #expect {
    try GraphcodeCommand.parse(["mailroom", "sync", "/tmp/x", "--search", "x"])
  } throws: { error in
    error as? GraphcodeCommand.ParseError == .unknownOption("--search")
  }
}

@Test
func readParsesAPostIDAndRejectsNonNumericOnes() throws {
  #expect(
    try GraphcodeCommand.parse(["mailroom", "read", "/tmp/x", "7"])
      == .mailroomRead(projectPath: "/tmp/x", postID: 7))

  #expect {
    try GraphcodeCommand.parse(["mailroom", "read", "/tmp/x", "seven"])
  } throws: { error in
    error as? GraphcodeCommand.ParseError
      == .invalidValue(argument: "post-id", value: "seven")
  }

  #expect {
    try GraphcodeCommand.parse(["mailroom", "read", "/tmp/x"])
  } throws: { error in
    error as? GraphcodeCommand.ParseError == .missingArgument("post-id")
  }
}

@Test
func listParsesSearchAndJSON() throws {
  #expect(
    try GraphcodeCommand.parse(["mailroom", "list", "/tmp/x", "--search", "auth", "--json"])
      == .mailroomList(projectPath: "/tmp/x", search: "auth", json: true))
  #expect(
    try GraphcodeCommand.parse(["mailroom", "list", "/tmp/x"])
      == .mailroomList(projectPath: "/tmp/x", search: nil, json: false))
}

@Test
func headlinesCutBodiesToATriageLine() {
  let (graph, reader) = boardWithPosts()

  let headlines = GraphcodeCommand.renderMailroom(
    served(graph, .unread(reader: reader.id), fullBodies: false), project: graph.project,
    unread: true, headlines: true)
  #expect(headlines.contains("#2 (build)"))
  #expect(!headlines.contains("red red red red red red red red red red red red"))
  // Asked for, so no "headlines only" apology on the header line.
  #expect(!headlines.contains("headlines only"))
  let full = GraphcodeCommand.renderMailroom(
    served(graph, .unread(reader: reader.id), fullBodies: true), project: graph.project,
    unread: true)
  #expect(full.contains("red red"))
}

@Test
func aRoomThatTriagedItselfSaysSoAndWhereTheFullTextIs() {
  var graph = LoopGraph(project: ProjectRef(path: "/tmp/x", name: "x"))
  graph.mailroom = (1...(Mailroom.triageAfterPosts + 1)).map {
    MailroomPost(
      id: $0, at: Date(timeIntervalSince1970: 0), authorID: nil, author: "a human",
      topic: nil, body: String(repeating: "word ", count: 30))
  }
  let reader = UUID()

  let triaged = GraphcodeCommand.renderMailroom(
    served(graph, .unread(reader: reader)), project: graph.project, unread: true)
  #expect(triaged.contains("headlines only, that is a lot to read at once"))
  #expect(triaged.contains("graphcode mail read /tmp/x <post-id>"))
  #expect(triaged.split(separator: "\n").count == graph.mailroom.count + 1)
  #expect(triaged.split(separator: "\n").dropFirst().allSatisfy { $0.hasSuffix("…") })
  // A room that cut the bodies renders the very lines the whole bodies would have.
  let whole = GraphcodeCommand.renderMailroom(
    served(graph, .unread(reader: reader), fullBodies: true), project: graph.project,
    unread: true, headlines: true)
  #expect(triaged.split(separator: "\n").dropFirst() == whole.split(separator: "\n").dropFirst())
}

@Test
func aPageSaysWhatItLeftAndJSONSaysSoOnlyThen() throws {
  var graph = LoopGraph(project: ProjectRef(path: "/tmp/x", name: "x"))
  graph.mailroom = (1...(Mailroom.inboxPageSize + 2)).map {
    MailroomPost(
      id: $0, at: Date(timeIntervalSince1970: 0), authorID: nil, author: "a human",
      topic: nil, body: "note \($0)")
  }
  let reader = UUID()

  let page = served(graph, .unread(reader: reader), fullBodies: true)
  let rendered = GraphcodeCommand.renderMailroom(page, project: graph.project, unread: true)
  #expect(
    rendered.hasSuffix(
      "2 more unread past #\(Mailroom.inboxPageSize) — run the same command again for the next page"
    ))
  #expect(rendered.split(separator: "\n").count == Mailroom.inboxPageSize + 2)

  struct Board: Decodable {
    let posts: [MailroomPost]
    let remaining: Int?
  }
  let decoder = JSONDecoder()
  decoder.dateDecodingStrategy = .iso8601
  let paged = try decoder.decode(
    Board.self, from: try #require(GraphcodeCommand.renderMailroomJSON(page).data(using: .utf8)))
  #expect(paged.remaining == 2)
  #expect(paged.posts.count == Mailroom.inboxPageSize)

  let (small, smallReader) = boardWithPosts()
  let whole = try decoder.decode(
    Board.self,
    from: try #require(
      GraphcodeCommand.renderMailroomJSON(
        served(small, .unread(reader: smallReader.id), fullBodies: true)
      ).data(using: .utf8)))
  #expect(whole.remaining == nil)
  #expect(
    !GraphcodeCommand.renderMailroom(
      served(small, .unread(reader: smallReader.id)), project: small.project, unread: true
    ).contains("more unread"))
}

@Test
func prunedMailIsSaidOutLoudWithAndWithoutPosts() throws {
  var graph = LoopGraph(project: ProjectRef(path: "/tmp/x", name: "x"))
  var reader = LoopNode(title: "Reader", loopType: .turnBased)
  reader.lastMailroomRead = 2
  graph.nodes.append(reader)
  graph.mailroom = [
    MailroomPost(
      id: 2, at: Date(timeIntervalSince1970: 0), authorID: nil, author: "a human",
      topic: nil, body: "read"),
    MailroomPost(
      id: 6, at: Date(timeIntervalSince1970: 1), authorID: nil, author: "a human",
      topic: nil, body: "survived"),
  ]

  let withPosts = GraphcodeCommand.renderMailroom(
    served(graph, .unread(reader: reader.id)), project: graph.project, unread: true)
  #expect(withPosts.contains("#6"))
  #expect(withPosts.contains("3 posts landed since your last inbox and were pruned"))

  graph.mailroom.removeLast()
  graph.mailroom.append(
    MailroomPost(
      id: 6, at: Date(timeIntervalSince1970: 1), authorID: nil, author: "a human",
      topic: nil, body: "survived"))
  graph.nodes[id: reader.id]?.lastMailroomRead = 6
  var gone = graph
  gone.mailroom = [graph.mailroom[0]]
  gone.nodes[id: reader.id]?.lastMailroomRead = 2
  // Only #2 survives; the cursor is at 2, nothing above it exists: nothing was pruned
  // *unread* — the count needs a surviving post above the cursor to be knowable.
  #expect(
    GraphcodeCommand.renderMailroom(
      served(gone, .unread(reader: reader.id)), project: graph.project, unread: true)
      == "no unread posts")

  // JSON says it only when there is something to say — read off the room as it stood
  // when three posts had been pruned unread.
  graph.nodes[id: reader.id]?.lastMailroomRead = 2
  struct Board: Decodable {
    let prunedUnread: Int?
  }
  let decoder = JSONDecoder()
  decoder.dateDecodingStrategy = .iso8601
  let pruned = try decoder.decode(
    Board.self,
    from: try #require(
      GraphcodeCommand.renderMailroomJSON(served(graph, .unread(reader: reader.id)))
        .data(using: .utf8)))
  #expect(pruned.prunedUnread == 3)
  let whole = try decoder.decode(
    Board.self,
    from: try #require(
      GraphcodeCommand.renderMailroomJSON(served(graph, .board, fullBodies: true))
        .data(using: .utf8)))
  #expect(whole.prunedUnread == nil)
}

@Test
func searchFiltersWhatIsShownButNeverWhatIsRemembered() {
  let (graph, reader) = boardWithPosts()

  // "deadlock" lives only in #3's body — note "auth" would have matched #2's
  // author ("Author"), which is the filter doing its job, not a bug.
  let filtered = GraphcodeCommand.renderMailroom(
    served(graph, .unread(reader: reader.id), search: "deadlock"), project: graph.project,
    unread: true, search: "deadlock")
  #expect(filtered.contains("#3"))
  #expect(!filtered.contains("#2"))

  #expect(
    GraphcodeCommand.renderMailroom(
      served(graph, .board, search: "nonesuch"), project: graph.project, unread: false,
      search: "nonesuch"
    ).contains("no posts match 'nonesuch'"))
  #expect(
    GraphcodeCommand.renderMailroom(
      served(graph, .unread(reader: reader.id), search: "nonesuch"), project: graph.project,
      unread: true, search: "nonesuch"
    ).contains("no unread posts match 'nonesuch'"))
}

@Test
func jsonRendersTheSameTruthInOtherSyntax() throws {
  struct Board: Decodable {
    let posts: [MailroomPost]
    let lastRead: Int?
  }
  let (graph, reader) = boardWithPosts()

  let forReader = try #require(
    GraphcodeCommand.renderMailroomJSON(
      served(graph, .unread(reader: reader.id), fullBodies: true)
    ).data(using: .utf8))
  let decoder = JSONDecoder()
  decoder.dateDecodingStrategy = .iso8601
  let decoded = try decoder.decode(Board.self, from: forReader)
  #expect(decoded.lastRead == 1)
  #expect(decoded.posts.map(\.id) == [2, 3])

  let whole = try #require(
    GraphcodeCommand.renderMailroomJSON(served(graph, .board, fullBodies: true))
      .data(using: .utf8))
  let everything = try decoder.decode(Board.self, from: whole)
  #expect(everything.posts.count == 3)
  #expect(everything.lastRead == nil)
}

@Test
func statusLineCountsPostsAndUnreadOnlyWhenThereAreAny() {
  let (graph, reader) = boardWithPosts()

  #expect(
    GraphcodeCommand.renderMailroomStatusLine(graph, readerID: reader.id)
      == "mailroom: 3 posts, unread mail for you")
  #expect(
    GraphcodeCommand.renderMailroomStatusLine(graph) == "mailroom: 3 posts")
  #expect(
    GraphcodeCommand.renderMailroomStatusLine(
      LoopGraph(project: ProjectRef(path: "/tmp/x", name: "x"))) == nil)

  // Off the digest, so the snapshot a client actually receives says the same.
  let wire = graph.wireSnapshot()
  #expect(
    GraphcodeCommand.renderMailroomStatusLine(wire, readerID: reader.id)
      == "mailroom: 3 posts, unread mail for you")
  var caughtUp = wire
  caughtUp.nodes[id: reader.id]?.lastMailroomRead = 3
  #expect(
    GraphcodeCommand.renderMailroomStatusLine(caughtUp, readerID: reader.id)
      == "mailroom: 3 posts, nothing unread for you")

  let rendered = GraphcodeCommand.render(wire, mailroomReader: reader.id)
  #expect(rendered.contains("mailroom: 3 posts, unread mail for you"))
}

// MARK: Read-side review round (status-line blast radius, json+search, boundaries)

@Test
func statusLineSurvivesAnEmptyNodeGraphWithHumanPosts() {
  var graph = LoopGraph(project: ProjectRef(path: "/tmp/x", name: "x"))
  graph.mailroom = [
    MailroomPost(
      id: 1, at: Date(timeIntervalSince1970: 0), authorID: nil, author: "a human",
      topic: nil, body: "written after the last loop was deleted")
  ]

  let rendered = GraphcodeCommand.render(graph)
  #expect(rendered.contains("no loops yet"))
  #expect(rendered.contains("mailroom: 1 post"))
}

@Test
func neverTouchedBoardRendersExactlyAsBeforeTheMailroom() {
  var graph = LoopGraph(project: ProjectRef(path: "/tmp/x", name: "x"))
  graph.nodes.append(LoopNode(title: "Solo", loopType: .turnBased, firstInstruction: "Work"))

  let rendered = GraphcodeCommand.render(graph, mailroomReader: UUID())
  #expect(!rendered.contains("mailroom:"))
  #expect(!rendered.contains("\n  edges:"))
}

@Test
func foreignReaderGetsThePlainCountLikeAHuman() {
  let (graph, _) = boardWithPosts()
  // The daemon refuses sync for a reader absent from this graph; the status line
  // claims no "unread for you" for one either.
  #expect(
    GraphcodeCommand.renderMailroomStatusLine(graph, readerID: UUID())
      == "mailroom: 3 posts")
}

@Test
func listJSONHonorsTheSearchFilter() throws {
  struct Board: Decodable {
    let posts: [MailroomPost]
  }
  let (graph, _) = boardWithPosts()

  let filtered = try #require(
    GraphcodeCommand.renderMailroomJSON(
      served(graph, .board, search: "deadlock", fullBodies: true)
    ).data(using: .utf8))
  let decoder = JSONDecoder()
  decoder.dateDecodingStrategy = .iso8601
  #expect(try decoder.decode(Board.self, from: filtered).posts.map(\.id) == [3])
}

@Test
func jsonDatesAreISOTwo8601NotTheEncoderDefault() throws {
  struct Board: Decodable {
    let posts: [MailroomPost]
  }
  let (graph, _) = boardWithPosts()
  let data = try #require(
    GraphcodeCommand.renderMailroomJSON(served(graph, .board, fullBodies: true))
      .data(using: .utf8))

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
    MailroomPost(id: 1, at: at, authorID: nil, author: "a human", topic: nil, body: "")
  )
  let exact = MailroomPost(
    id: 1, at: at, authorID: nil, author: "a human", topic: nil,
    body: String(repeating: "a", count: 80 - prefix.count))
  let over = MailroomPost(
    id: 1, at: at, authorID: nil, author: "a human", topic: nil,
    body: String(repeating: "a", count: 81 - prefix.count))

  #expect(GraphcodeCommand.renderHeadline(exact) == GraphcodeCommand.render(exact))
  #expect(GraphcodeCommand.renderHeadline(over).hasSuffix("…"))
  #expect(!GraphcodeCommand.renderHeadline(over).contains("\n"))
}
