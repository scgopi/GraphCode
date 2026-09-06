import Foundation
import MailroomKit
import Testing

@testable import GraphcodeKit

#if canImport(Darwin)
  import Darwin
#endif

/// The remote CLI shim is Python; these tests pin its wire contract by running the
/// exact source `RemoteGraphAccess` delivers against a socket whose other end is
/// Swift — every frame the shim sends is decoded with the same `JSONDecoder` and
/// types `graphcoded` itself uses, so a protocol drift fails here before it fails on
/// someone's build box.
@Suite
struct RemoteCLIShimTests {
  private static let project = "ssh://dev@build-box:2222/home/dev/widget"

  @Test
  func aMemoRidesTheWireExactlyAsTheSwiftCLIWould() throws {
    let nodeID = UUID()
    let sender = UUID()
    let run = try runShim(
      ["node", "memo", Self.project, nodeID.uuidString, "dead", "end:", "approach", "X"],
      environment: ["ZMX_SESSION": "graphcode-\(sender.uuidString)"])

    #expect(run.status == 0)
    #expect(run.stdout.contains("noted"))
    #expect(run.commands.first == .openProject(path: Self.project))
    #expect(
      run.commands.dropFirst().first
        == .graphCommand(
          projectPath: Self.project,
          command: .memoNode(nodeID, text: "dead end: approach X", from: sender)))
  }

  @Test
  func aCreatedNodeDecodesIntoAValidAttributedDraft() throws {
    let creator = UUID()
    let run = try runShim(
      [
        "node", "create", Self.project, "--title", "Fix issue 7", "--type", "goal",
        "--goal", "tests pass", "--predicate", "make test",
      ],
      environment: ["ZMX_SESSION": "graphcode-\(creator.uuidString)"])

    #expect(run.status == 0)
    let second = try #require(run.commands.dropFirst().first)
    guard case .graphCommand(let path, .createNode(let draft)) = second else {
      Issue.record("expected createNode, decoded \(second)")
      return
    }
    #expect(path == Self.project)
    // Folded to one word, exactly as `LoopName.folded` does it on the Mac.
    #expect(draft.title == "FixIssue7")
    #expect(draft.loopType == .goalBased)
    #expect(draft.goal?.summary == "tests pass")
    #expect(draft.goal?.predicate == "make test")
    // Run from inside a loop, the shim attributes the child to its creator the same
    // way the Swift CLI does — off `ZMX_SESSION`, with nothing passed explicitly.
    #expect(draft.createdBy == creator)
    #expect(draft.isValid)
  }

  @Test
  func aSendFromAHumanShellIsUnattributed() throws {
    let nodeID = UUID()
    let run = try runShim(
      ["node", "send", Self.project, nodeID.uuidString, "the", "API", "changed"])

    #expect(run.status == 0)
    #expect(run.stdout.contains("delivered"))
    #expect(
      run.commands.dropFirst().first
        == .graphCommand(
          projectPath: Self.project,
          command: .messageNode(nodeID, text: "the API changed", from: nil, followUp: nil)))
  }

  /// The path a loop *on that host* naturally types — its working directory, or the
  /// worktree it was told to work in. The daemon keys graphs by the `ssh://` URI and
  /// opening one is create-if-missing, so this used to add a second project named after
  /// the worktree and put the child loop inside it. The shim is the one place that knows
  /// this is a remote host's spelling, so it is where the two are matched up.
  @Test
  func aLocalPathOnTheRemoteHostResolvesToItsProject() throws {
    let run = try runShim([
      "node", "create", "/home/dev/widget/worktrees/fix-215",
      "--title", "Fix 215", "--type", "goal", "--goal", "tests pass",
    ])

    #expect(run.status == 0)
    #expect(run.commands.first == .listRecentProjects)
    #expect(run.commands.dropFirst().first == .openProject(path: Self.project))
    guard case .graphCommand(let path, .createNode) = run.commands.last else {
      Issue.record("expected a createNode against the resolved project, got \(run.commands)")
      return
    }
    #expect(path == Self.project)
    #expect(run.stderr.contains(Self.project))
  }

  /// A path on that host belonging to no known project stays as it was typed: the daemon
  /// answers with the error naming it, rather than the shim inventing a project.
  @Test
  func anUnrelatedLocalPathIsLeftForTheDaemonToRefuse() throws {
    let run = try runShim(["status", "/home/dev/somewhere-else"])

    #expect(run.commands.first == .listRecentProjects)
    #expect(run.commands.dropFirst().first == .openProject(path: "/home/dev/somewhere-else"))
  }

  // MARK: - Harness

  private struct ShimRun {
    var status: Int32
    var stdout: String
    var stderr: String
    var commands: [DaemonCommand]
  }

  private final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [DaemonCommand] = []
    func append(_ command: DaemonCommand) {
      lock.lock()
      commands.append(command)
      lock.unlock()
    }
    var all: [DaemonCommand] {
      lock.lock()
      defer { lock.unlock() }
      return commands
    }
  }

  private struct HarnessError: Error {}

  /// Runs the delivered shim source against a one-connection Swift daemon stand-in
  /// that answers every decoded command with a `graphChanged` — the acknowledgement
  /// shape the real daemon uses.
  private func runShim(
    _ arguments: [String], environment: [String: String] = [:], graph: LoopGraph? = nil
  ) throws -> ShimRun {
    // Under `/tmp` rather than `NSTemporaryDirectory()`, whose per-user path can push
    // the socket past `sun_path`'s 104 bytes.
    let socketPath = "/tmp/graphcode-shim-\(UUID().uuidString.prefix(8)).sock"
    defer { unlink(socketPath) }

    let listener = socket(AF_UNIX, SOCK_STREAM, 0)
    guard listener >= 0 else { throw HarnessError() }
    defer { close(listener) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutablePointer(to: &address.sun_path) { field in
      field.withMemoryRebound(
        to: CChar.self, capacity: MemoryLayout.size(ofValue: field.pointee)
      ) { pointer in
        _ = socketPath.withCString {
          strncpy(pointer, $0, MemoryLayout.size(ofValue: field.pointee) - 1)
        }
      }
    }
    let bound = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bound == 0, listen(listener, 1) == 0 else { throw HarnessError() }

    let received = Received()
    DispatchQueue.global().async {
      let client = accept(listener, nil, nil)
      guard client >= 0 else { return }
      defer { close(client) }
      let graph = graph ?? LoopGraph(project: ProjectRef(path: Self.project, name: "widget"))
      while let data = try? FramedMessageIO.readFrame(from: client) {
        guard let command = try? JSONDecoder().decode(DaemonCommand.self, from: data)
        else { return }
        received.append(command)
        // The shapes the real daemon answers with: a snapshot carries the room's
        // digest and no posts, and a mailbox request is answered off the room itself.
        let event: DaemonEvent
        switch command {
        case .listRecentProjects:
          event = .recentProjectsListed([ProjectRef(path: Self.project, name: "widget")])
        case .mailbox(_, let query):
          event = .mailbox(
            projectPath: Self.project,
            mailbox: Mailroom.serve(query, from: graph.mailroom) {
              graph.nodes[id: $0]?.lastMailroomRead
            })
        default:
          event = .graphChanged(graph.wireSnapshot())
        }
        guard let reply = try? JSONEncoder().encode(event),
          (try? FramedMessageIO.writeFrame(reply, to: client)) != nil
        else { return }
      }
    }

    let shimFile = FileManager.default.temporaryDirectory
      .appendingPathComponent("graphcode-shim-\(UUID().uuidString).py")
    try RemoteGraphAccess.cliShimSource.write(to: shimFile, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: shimFile) }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["python3", shimFile.path] + arguments
    var processEnvironment = ProcessInfo.processInfo.environment
    // The test may itself be running inside a zmx session; a leaked `ZMX_SESSION`
    // would attribute the "human shell" case to whatever loop ran the tests.
    processEnvironment.removeValue(forKey: "ZMX_SESSION")
    processEnvironment["GRAPHCODE_SOCKET"] = socketPath
    for (key, value) in environment { processEnvironment[key] = value }
    process.environment = processEnvironment
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()

    return ShimRun(
      status: process.terminationStatus,
      stdout: String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
      stderr: String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
      commands: received.all)
  }
}

/// The board verbs, split into their own extension: `RemoteCLIShimTests` sits at
/// swiftlint's 350-line `type_body_length` error without them.
extension RemoteCLIShimTests {
  /// Served the way `GraphStore.mailbox` serves it; the shim asks the daemon for exactly
  /// this, so the renderers on both sides are handed the same posts.
  fileprivate static func served(
    _ graph: LoopGraph, _ selection: MailboxQuery.Selection, search: String? = nil,
    fullBodies: Bool? = nil
  ) -> Mailbox {
    Mailroom.serve(
      MailboxQuery(selection: selection, search: search, fullBodies: fullBodies),
      from: graph.mailroom
    ) { graph.nodes[id: $0]?.lastMailroomRead }
  }

  /// The board the parity tests drive: a cursor that leaves one post read, a topic and
  /// a bare byline, a body long enough that a headline has to cut it, and one carrying
  /// the slashes and the em dash that separate Swift's JSON escaping from Python's.
  /// Dates are fixed so the reference-date conversion is pinned, not merely exercised.
  private static func board() -> (LoopGraph, LoopNode) {
    var graph = LoopGraph(project: ProjectRef(path: project, name: "widget"))
    var reader = LoopNode(title: "Reader", loopType: .goalBased)
    reader.lastMailroomRead = 1
    graph.nodes.append(reader)
    graph.mailroom = [
      MailroomPost(
        id: 1, at: Date(timeIntervalSince1970: 1_756_000_000), authorID: nil,
        author: "a human", topic: nil, body: "already read"),
      MailroomPost(
        id: 2, at: Date(timeIntervalSince1970: 1_756_003_600), authorID: UUID(),
        author: "BuildWatch", topic: "build",
        body: String(repeating: "the gate is red ", count: 12)),
      MailroomPost(
        id: 3, at: Date(timeIntervalSince1970: 1_756_007_200), authorID: nil,
        author: "a human", topic: nil,
        // A path and a URL on purpose: Swift's JSONEncoder escapes `/` as `\/` and
        // Python's json.dumps does not, so a fixture without one lets `--json` drift
        // apart silently. This is the body that catches it.
        body: "claiming issue #12 — see docs/281.md and https://example.test/a/b",
        kind: .letter),
    ]
    return (graph, reader)
  }

  /// The renderer is duplicated — Swift on the Mac, Python on the remote host — and a
  /// defective copy propagates to every remote host on the next ensure, because
  /// `cliShimStamp` is content-derived. Byte equality against the production Swift
  /// renderer, through the production shim source, is the only thing that makes the
  /// duplication safe; nothing here compares against a string written by hand.
  @Test
  func theBoardRendersByteEqualToTheSwiftRenderer() throws {
    let (graph, reader) = Self.board()
    let session = ["ZMX_SESSION": "graphcode-\(reader.id.uuidString)"]

    func served(
      _ selection: MailboxQuery.Selection, search: String? = nil, fullBodies: Bool? = nil
    ) -> Mailbox {
      Self.served(graph, selection, search: search, fullBodies: fullBodies)
    }
    let project = graph.project
    let cases: [(arguments: [String], environment: [String: String], expected: String)] = [
      (
        ["mailroom", "list", Self.project], [:],
        GraphcodeCommand.renderMailroom(
          served(.board, fullBodies: true), project: project, unread: false)
      ),
      (
        ["mailroom", "list", Self.project, "--search", "RED"], [:],
        GraphcodeCommand.renderMailroom(
          served(.board, search: "RED", fullBodies: true), project: project, unread: false,
          search: "RED")
      ),
      (
        ["mailroom", "list", Self.project, "--search", "nothing-matches"], [:],
        GraphcodeCommand.renderMailroom(
          served(.board, search: "nothing-matches", fullBodies: true), project: project,
          unread: false, search: "nothing-matches")
      ),
      (
        ["mailroom", "sync", Self.project], session,
        GraphcodeCommand.renderMailroom(
          served(.unread(reader: reader.id)), project: project, unread: true)
      ),
      (
        ["mailroom", "sync", Self.project, "--headlines"], session,
        GraphcodeCommand.renderMailroom(
          served(.unread(reader: reader.id), fullBodies: false), project: project, unread: true,
          headlines: true)
      ),
      (
        ["mailroom", "sync", Self.project, "--full"], session,
        GraphcodeCommand.renderMailroom(
          served(.unread(reader: reader.id), fullBodies: true), project: project, unread: true)
      ),
      (
        ["mailroom", "read", Self.project, "2"], [:],
        GraphcodeCommand.render(graph.mailroom[1])
      ),
      (
        ["mailroom", "list", Self.project, "--json"], [:],
        GraphcodeCommand.renderMailroomJSON(served(.board, fullBodies: true))
      ),
      (
        ["mailroom", "sync", Self.project, "--json"], session,
        GraphcodeCommand.renderMailroomJSON(served(.unread(reader: reader.id), fullBodies: true))
      ),
      (
        ["mailroom", "sync", Self.project, "--mark"], session,
        "marked read up to #3"
      ),
    ]

    for testCase in cases {
      let run = try runShim(testCase.arguments, environment: testCase.environment, graph: graph)
      #expect(run.status == 0, "\(testCase.arguments) failed: \(run.stderr)")
      #expect(
        run.stdout == testCase.expected + "\n",
        "\(testCase.arguments)\nshim:  \(run.stdout)\nswift: \(testCase.expected)")
    }
  }

  /// A board with nothing on it, and a caught-up reader, are the two shapes the parity
  /// fixture cannot reach — and both are what a loop meets on its very first pass.
  @Test
  func anEmptyBoardAndACaughtUpReaderRenderByteEqualToo() throws {
    var graph = LoopGraph(project: ProjectRef(path: Self.project, name: "widget"))
    var reader = LoopNode(title: "Reader", loopType: .goalBased)
    reader.lastMailroomRead = 3
    graph.nodes.append(reader)

    let empty = try runShim(["mailroom", "list", Self.project], graph: graph)
    #expect(
      empty.stdout
        == GraphcodeCommand.renderMailroom(
          Mailroom.serve(MailboxQuery(selection: .board, fullBodies: true), from: []) { _ in nil },
          project: graph.project, unread: false) + "\n")

    graph.mailroom = [
      MailroomPost(
        id: 3, at: Date(timeIntervalSince1970: 1_756_000_000), authorID: nil,
        author: "a human", topic: nil, body: "caught up")
    ]
    let synced = try runShim(
      ["mailroom", "sync", Self.project],
      environment: ["ZMX_SESSION": "graphcode-\(reader.id.uuidString)"], graph: graph)
    #expect(synced.stdout == "no unread posts\n")
  }

  /// `at` crosses the wire as a Foundation reference-date interval — seconds since
  /// 2001-01-01, not since the epoch — so a shim that formatted it as epoch would print
  /// a date 31 years early. Pinned against the formatter the Swift CLI actually uses.
  @Test
  func theStampConvertsFromFoundationsReferenceDate() throws {
    let (graph, _) = Self.board()
    let stamp = MailroomPost.stampFormat.string(from: graph.mailroom[0].at)
    let run = try runShim(["mailroom", "read", Self.project, "1"], graph: graph)
    #expect(run.stdout == "#1 from a human at \(stamp) — already read\n")

    // The stamp cannot carry the whole guard on its own. `MMM d, HH:mm` has no year,
    // and the offset is 978307200 seconds — exactly 11323 days, which is exactly 31
    // years across this span's eight leap days — so dropping it entirely renders the
    // *identical* stamp, "Aug 23, 18:46" either way. The year rides `--json`'s
    // ISO-8601 instead, where the same mistake cannot hide.
    let json = try runShim(["mailroom", "list", Self.project, "--json"], graph: graph)
    #expect(json.stdout.contains("\"at\":\"2025-08-24T01:46:40Z\""))
    #expect(!json.stdout.contains("\"at\":\"1994-"))
  }

  /// The triage boundary, both halves of it: `Mailroom.needsTriage` is more than 12
  /// posts *or* more than 4096 bytes of body, and a sync that trips either one prints
  /// headlines and says so. Off-by-one here silently truncates a board a loop was told
  /// it had read in full.
  @Test
  func triageTripsAtTwelvePostsAndAtFourKilobytes() throws {
    func syncOutput(posts: Int, bodyBytes: Int) throws -> (String, String) {
      var graph = LoopGraph(project: ProjectRef(path: Self.project, name: "widget"))
      let reader = LoopNode(title: "Reader", loopType: .goalBased)
      graph.nodes.append(reader)
      let each = bodyBytes / posts
      graph.mailroom = (1...posts).map { index in
        MailroomPost(
          id: index, at: Date(timeIntervalSince1970: 1_756_000_000 + Double(index)),
          authorID: nil, author: "a human", topic: nil,
          body: String(
            repeating: "x", count: index == posts ? bodyBytes - each * (posts - 1) : each)
        )
      }
      let run = try runShim(
        ["mailroom", "sync", Self.project],
        environment: ["ZMX_SESSION": "graphcode-\(reader.id.uuidString)"], graph: graph)
      return (
        run.stdout,
        GraphcodeCommand.renderMailroom(
          Self.served(graph, .unread(reader: reader.id)), project: graph.project, unread: true)
          + "\n"
      )
    }

    // Twelve posts well under the byte cap: full bodies, no announcement.
    let (twelve, twelveSwift) = try syncOutput(posts: 12, bodyBytes: 120)
    #expect(twelve == twelveSwift)
    #expect(!twelve.contains("headlines only"))

    let (thirteen, thirteenSwift) = try syncOutput(posts: 13, bodyBytes: 130)
    #expect(thirteen == thirteenSwift)
    #expect(thirteen.contains("headlines only"))

    // Bytes, at the boundary: 4096 is not "more than", 4097 is.
    let (atCap, atCapSwift) = try syncOutput(posts: 8, bodyBytes: 4096)
    #expect(atCap == atCapSwift)
    #expect(!atCap.contains("headlines only"))

    let (overCap, overCapSwift) = try syncOutput(posts: 8, bodyBytes: 4097)
    #expect(overCap == overCapSwift)
    #expect(overCap.contains("headlines only"))
  }

  /// `status` is where the briefing sends a loop before it claims work, and the board
  /// line is what makes "is there mail I should care about" free. It was absent from
  /// the shim's own render even though the snapshot carrying it was already in hand.
  @Test
  func statusCarriesTheBoardLineTheLocalCLIPrints() throws {
    let (graph, reader) = Self.board()

    let asReader = try runShim(
      ["status", Self.project],
      environment: ["ZMX_SESSION": "graphcode-\(reader.id.uuidString)"], graph: graph)
    let readerLine = try #require(
      GraphcodeCommand.renderMailroomStatusLine(graph, readerID: reader.id))
    #expect(readerLine == "mailroom: 3 posts, unread mail for you")
    #expect(asReader.stdout.hasSuffix("  " + readerLine + "\n"))

    // A human shell, and a loop this graph has never heard of, both get the plain
    // count — the daemon would refuse a cursor for either.
    let asHuman = try runShim(["status", Self.project], graph: graph)
    let plain = try #require(GraphcodeCommand.renderMailroomStatusLine(graph))
    #expect(plain == "mailroom: 3 posts")
    #expect(asHuman.stdout.hasSuffix("  " + plain + "\n"))

    let asStranger = try runShim(
      ["status", Self.project],
      environment: ["ZMX_SESSION": "graphcode-\(UUID().uuidString)"], graph: graph)
    #expect(asStranger.stdout.hasSuffix("  " + plain + "\n"))

    // A project that never touched the board renders exactly as it did before.
    let untouched = try runShim(
      ["status", Self.project],
      graph: LoopGraph(project: ProjectRef(path: Self.project, name: "widget")))
    #expect(!untouched.stdout.contains("mailroom"))
  }

  @Test
  func postSyncAndWatchRideTheWireExactlyAsTheSwiftCLIWould() throws {
    let (graph, reader) = Self.board()
    let session = ["ZMX_SESSION": "graphcode-\(reader.id.uuidString)"]

    let posted = try runShim(
      ["mailroom", "post", Self.project, "--topic", "claims", "issue", "#12", "is", "mine"],
      environment: session, graph: graph)
    #expect(posted.status == 0)
    #expect(posted.stdout == GraphcodeCommand.renderPosted(graph, topic: "claims") + "\n")
    #expect(posted.stdout == "posted #3 (claims)\n")
    #expect(
      posted.commands.dropFirst().first
        == .graphCommand(
          projectPath: Self.project,
          command: .mailroomPost(text: "issue #12 is mine", topic: "claims", from: reader.id)))

    // A human's post is unattributed, exactly as `node send` from a shell is.
    let byHuman = try runShim(
      ["mailroom", "post", Self.project, "the", "board", "is", "for", "everyone"], graph: graph)
    #expect(
      byHuman.commands.dropFirst().first
        == .graphCommand(
          projectPath: Self.project,
          command: .mailroomPost(
            text: "the board is for everyone", topic: nil, from: nil)))

    // `--mark` walks the unread mail through the mailbox, headlines only, page by
    // page — never the legacy `mailroomInbox`, which a daemon now refuses.
    let synced = try runShim(
      ["mailroom", "sync", Self.project, "--mark"], environment: session, graph: graph)
    #expect(synced.stdout == "marked read up to #3\n")
    #expect(
      synced.commands.dropFirst().first
        == .mailbox(
          projectPath: Self.project,
          query: MailboxQuery(
            selection: .unread(reader: reader.id), fullBodies: false, advanceCursor: true)))
    #expect(
      !synced.commands.contains { if case .graphCommand = $0 { return true } else { return false } }
    )

    let watching = try runShim(
      ["mailroom", "watch", Self.project, "--topic", "build"], environment: session,
      graph: graph)
    #expect(watching.stdout.hasPrefix("watching 'build' —"))
    #expect(
      watching.commands.dropFirst().first
        == .graphCommand(
          projectPath: Self.project,
          command: .mailroomWatch(on: true, topic: "build", from: reader.id)))

    let unwatching = try runShim(
      ["mailroom", "watch", Self.project, "--off"], environment: session, graph: graph)
    #expect(unwatching.stdout == "stopped watching\n")
    #expect(
      unwatching.commands.dropFirst().first
        == .graphCommand(
          projectPath: Self.project,
          command: .mailroomWatch(on: false, topic: nil, from: reader.id)))
  }

  /// Swift measures a headline in extended grapheme clusters and Python in code points,
  /// so the cut drifts apart on anything built out of combining sequences — and can land
  /// between a base character and its mark, ending a remote headline on a mangled glyph.
  /// Every join that actually reaches a note, driven through both renderers.
  @Test
  func headlinesCutAtTheSameGraphemeClusterTheMacDoes() throws {
    let bodies = [
      // Decomposed accents: 2 code points each, 1 character each.
      String(repeating: "a\u{0301}", count: 70),
      // ZWJ family: 7 code points, 1 character.
      String(repeating: "👨‍👩‍👧‍👦", count: 20),
      // Skin-tone modifier, regional-indicator flag, and a keycap sequence.
      String(repeating: "👋🏽🇯🇵1️⃣", count: 20),
      // Mixed, so the cut lands mid-sequence rather than tidily between them.
      "release notes: " + String(repeating: "e\u{0301}👨‍👩‍👧‍👦x", count: 20),
      // Astral without any joining, and text that needs no clustering at all.
      String(repeating: "𝔊", count: 90),
      String(repeating: "plain ascii ", count: 12),
    ]

    for (index, body) in bodies.enumerated() {
      var graph = LoopGraph(project: ProjectRef(path: Self.project, name: "widget"))
      graph.mailroom = [
        MailroomPost(
          id: 1, at: Date(timeIntervalSince1970: 1_756_000_000), authorID: nil,
          author: "a human", topic: nil, body: body)
      ]
      let reader = LoopNode(title: "Reader", loopType: .goalBased)
      graph.nodes.append(reader)

      let run = try runShim(
        ["mailroom", "sync", Self.project, "--headlines"],
        environment: ["ZMX_SESSION": "graphcode-\(reader.id.uuidString)"], graph: graph)
      let expected = GraphcodeCommand.renderMailroom(
        Self.served(graph, .unread(reader: reader.id), fullBodies: false), project: graph.project,
        unread: true, headlines: true)
      #expect(run.stdout == expected + "\n", "body \(index) cut differently")
    }
  }

  /// `--search` is how a loop asks whether mail on a subject exists. Swift's
  /// `String.contains` compares canonically, so a decomposed body matches a precomposed
  /// needle on the Mac; a code-point test would answer "no posts match" remotely and
  /// report that the mail does not exist.
  @Test
  func searchMatchesCanonicallyEquivalentTextAsSwiftDoes() throws {
    var graph = LoopGraph(project: ProjectRef(path: Self.project, name: "widget"))
    graph.mailroom = [
      MailroomPost(
        id: 1, at: Date(timeIntervalSince1970: 1_756_000_000), authorID: nil,
        author: "a human", topic: nil, body: "shipped the e\u{0301}clair build"),
      MailroomPost(
        id: 2, at: Date(timeIntervalSince1970: 1_756_003_600), authorID: nil,
        author: "Ame\u{0301}lie", topic: "cafe\u{0301}", body: "unrelated"),
    ]

    // Precomposed needles against decomposed body, author and topic — and the reverse.
    for needle in ["éclair", "e\u{0301}clair", "Amélie", "café", "ÉCLAIR"] {
      let run = try runShim(
        ["mailroom", "list", Self.project, "--search", needle], graph: graph)
      let expected = GraphcodeCommand.renderMailroom(
        Self.served(graph, .board, search: needle, fullBodies: true), project: graph.project,
        unread: false, search: needle)
      #expect(run.stdout == expected + "\n", "search '\(needle)' diverged")
      #expect(!expected.hasPrefix("no posts match"), "fixture no longer exercises a match")
    }
  }

  /// The parser's remaining shape, matched to `parseMailroom`: a `--flag` is never a
  /// project path, and a topic is an Optional rather than a truthiness test — the empty
  /// topic the daemon refuses today still has to render the way Swift renders it, or
  /// this is a second rule the renderer would need re-auditing against if that moved.
  @Test
  func theParserAndTheEmptyTopicMatchTheSwiftCLIsShape() throws {
    let missingPath = try runShim(["mailroom", "list", "--json"])
    #expect(missingPath.status == 1)
    #expect(missingPath.stderr.contains("missing project-path"))
    // Refused before the dial, so the daemon is never asked to open a project called
    // "--json" — nothing reaches the graph to be undone.
    #expect(missingPath.commands.isEmpty)

    var graph = LoopGraph(project: ProjectRef(path: Self.project, name: "widget"))
    graph.mailroom = [
      MailroomPost(
        id: 5, at: Date(timeIntervalSince1970: 1_756_000_000), authorID: nil,
        author: "a human", topic: "", body: "a topic that is present but empty")
    ]
    let run = try runShim(["mailroom", "read", Self.project, "5"], graph: graph)
    #expect(run.stdout == GraphcodeCommand.render(graph.mailroom[0]) + "\n")
    #expect(run.stdout.contains("#5 () from a human"))

    // The sequence number comes off the digest and the topic is the caller's — spelled
    // the way the daemon keeps it, and absent when there was none.
    let posted = try runShim(
      ["mailroom", "post", Self.project, "anything"], graph: graph)
    #expect(posted.stdout == GraphcodeCommand.renderPosted(graph) + "\n")
    #expect(posted.stdout == "posted #5\n")
    let spelled = try runShim(
      ["mailroom", "post", Self.project, "--topic", " Claims ", "anything"], graph: graph)
    #expect(spelled.stdout == GraphcodeCommand.renderPosted(graph, topic: " Claims ") + "\n")
    #expect(spelled.stdout == "posted #5 (claims)\n")
  }

  /// A plain `inbox` is one request: the page of unread posts and the cursor advance
  /// ride the same `mailbox`, with no `mailroomInbox` behind it — the way the Swift CLI
  /// sends it. `--mark` is the one spelling that still marks everything read, unseen.
  @Test
  func inboxAsksForOnePageAndMovesTheCursorInTheSameRequest() throws {
    let (graph, reader) = Self.board()
    let session = ["ZMX_SESSION": "graphcode-\(reader.id.uuidString)"]

    let inbox = try runShim(
      ["mailroom", "inbox", Self.project], environment: session, graph: graph)
    #expect(inbox.status == 0)
    #expect(
      inbox.commands == [
        .openProject(path: Self.project),
        .mailbox(
          projectPath: Self.project,
          query: MailboxQuery(selection: .unread(reader: reader.id), advanceCursor: true)),
      ])

    let full = try runShim(
      ["mailroom", "inbox", Self.project, "--json"], environment: session, graph: graph)
    #expect(
      full.commands.last
        == .mailbox(
          projectPath: Self.project,
          query: MailboxQuery(
            selection: .unread(reader: reader.id), fullBodies: true, advanceCursor: true)))
  }

  /// A backlog longer than a page prints the page and says what it left, byte-equal
  /// to the Swift renderer — in text and in `--json`.
  @Test
  func aPagedBacklogRendersByteEqualToo() throws {
    var graph = LoopGraph(project: ProjectRef(path: Self.project, name: "widget"))
    let reader = LoopNode(title: "Reader", loopType: .goalBased)
    graph.nodes.append(reader)
    graph.mailroom = (1...(Mailroom.inboxPageSize + 3)).map { index in
      MailroomPost(
        id: index, at: Date(timeIntervalSince1970: 1_756_000_000 + Double(index)),
        authorID: nil, author: "a human", topic: nil, body: "note \(index)")
    }
    let session = ["ZMX_SESSION": "graphcode-\(reader.id.uuidString)"]

    let text = try runShim(
      ["mailroom", "inbox", Self.project], environment: session, graph: graph)
    let expected = GraphcodeCommand.renderMailroom(
      Self.served(graph, .unread(reader: reader.id)), project: graph.project, unread: true)
    #expect(text.stdout == expected + "\n")
    #expect(text.stdout.contains("3 more unread past #\(Mailroom.inboxPageSize)"))

    let json = try runShim(
      ["mailroom", "inbox", Self.project, "--json"], environment: session, graph: graph)
    #expect(
      json.stdout
        == GraphcodeCommand.renderMailroomJSON(
          Self.served(graph, .unread(reader: reader.id), fullBodies: true)) + "\n")
    #expect(json.stdout.contains("\"remaining\":3"))
  }

  /// `read` and `list` ask the mailbox for exactly what they print and send no command —
  /// so neither can move a cursor by accident — and they ask the way the Swift CLI asks:
  /// one post whole, or the whole room with every body.
  @Test
  func readAndListAskTheMailboxAndMoveNoCursor() throws {
    let (graph, _) = Self.board()
    let read = try runShim(["mailroom", "read", Self.project, "3"], graph: graph)
    #expect(read.status == 0)
    #expect(
      read.commands == [
        .openProject(path: Self.project),
        .mailbox(projectPath: Self.project, query: MailboxQuery(selection: .post(id: 3))),
      ])

    let list = try runShim(["mailroom", "list", Self.project, "--search", "gate"], graph: graph)
    #expect(list.status == 0)
    #expect(
      list.commands == [
        .openProject(path: Self.project),
        .mailbox(
          projectPath: Self.project,
          query: MailboxQuery(selection: .board, search: "gate", fullBodies: true)),
      ])
  }

  /// The cursor verbs refuse a human shell up front, in the Swift CLI's own wording,
  /// rather than after a round trip — and `mailroom` no longer falls through to the
  /// "Mac-only" refusal that made every verb on this list exit 1.
  @Test
  func theCursorVerbsNeedALoopIdentityAndMailroomIsNoLongerMacOnly() throws {
    let sync = try runShim(["mailroom", "sync", Self.project])
    #expect(sync.status == 1)
    #expect(sync.stderr.contains("mail inbox needs a loop identity"))
    #expect(sync.stderr.contains("graphcode mail list"))

    let watch = try runShim(["mailroom", "watch", Self.project])
    #expect(watch.status == 1)
    #expect(watch.stderr.contains("mail watch needs a loop identity"))
    #expect(watch.stderr.contains("the mail is delivered to the loop that watches"))

    // Neither reached the daemon, so nothing was applied and nothing needs undoing.
    #expect(sync.commands.isEmpty)
    #expect(watch.commands.isEmpty)

    for verb in ["post", "inbox", "sync", "read", "list", "watch"] {
      let run = try runShim(["mail", verb])
      #expect(!run.stderr.contains("Mac-only"), "mail \(verb) still refused as Mac-only")
    }
    // The pre-rename spellings still reach the same parser: loops relaunched with a
    // briefing written before the rename type `artifactory sync`, and must not be told
    // the verb is Mac-only.
    for verb in ["mailroom", "artifactory"] {
      let run = try runShim([verb, "sync"])
      #expect(!run.stderr.contains("Mac-only"), "\(verb) sync still refused as Mac-only")
      #expect(!run.stderr.contains("unknown"), "\(verb) sync no longer parses")
    }
    // A subcommand that genuinely does not exist says so as the Swift CLI does.
    let bogus = try runShim(["mailroom", "resolve", Self.project])
    #expect(bogus.status == 1)
    #expect(bogus.stderr.contains("unknown command: mail resolve"))
    // And a mistyped flag is refused rather than silently ignored.
    let mistyped = try runShim(["mailroom", "list", Self.project, "--serach", "red"])
    #expect(mistyped.status == 1)
    #expect(mistyped.stderr.contains("unknown option: --serach"))
  }

  @Test
  func readNamesTheIdsThatExistWhenThePostIsGone() throws {
    let (graph, _) = Self.board()
    let missing = try runShim(["mailroom", "read", Self.project, "99"], graph: graph)
    #expect(missing.status == 1)
    #expect(missing.stderr.contains("no post #99 on this board"))
    #expect(missing.stderr.contains("graphcode mail list"))

    let negative = try runShim(["mailroom", "read", Self.project, "-7"], graph: graph)
    #expect(negative.status == 1)
    #expect(negative.stderr.contains("invalid value for post-id: -7"))
    #expect(negative.commands.isEmpty)
  }

  @Test
  func theHelpTextTeachesEveryVerbTheBriefingDoes() throws {
    let help = try runShim(["mailroom", "--help"])
    #expect(help.status == 0)
    for verb in ["post", "inbox", "read", "list", "watch"] {
      #expect(help.stdout.contains("graphcode mail \(verb) "))
    }
    // The shim's own honesty rule: nothing it implements may sit on the Mac-only list.
    #expect(!help.stdout.contains("(update, pilot, arm, edge, usage, mailroom)"))
  }
}
