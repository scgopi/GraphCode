import Foundation
import GraphcodeKit
import MailroomKit
import Testing

@testable import graphcode

/// What a machine that ran the Artifactory build still has on disk, and what its loops
/// still type. The rename is only safe if every old spelling is read, so these encode
/// the current shape, rewrite the keys back to the ones that shipped, and decode.
///
/// The round-trip is deliberate: hand-written JSON would pin a date strategy and a
/// field list that drift, and the question here is only whether the *key* is found.
@Suite
struct MailroomLegacyNamesTests {
  private static func rewritten(_ value: some Encodable, _ swaps: [(String, String)]) throws
    -> Data
  {
    var json = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    for (new, old) in swaps {
      json = json.replacingOccurrences(of: "\"\(new)\"", with: "\"\(old)\"")
    }
    return Data(json.utf8)
  }

  @Test
  func aRecordedChoiceToTurnTheBoardOffSurvivesTheRename() throws {
    // The Settings copy promises "your choice here is kept". Missing this key would
    // silently switch the section back on for everyone who had turned it off.
    let data = try Self.rewritten(
      GraphcodeSettings(mailroomEnabled: false), [("mailroomEnabled", "artifactoryEnabled")])
    #expect(try JSONDecoder().decode(GraphcodeSettings.self, from: data).mailroomEnabled == false)
  }

  @Test
  func theBoardItselfSurvivesTheRename() throws {
    var graph = LoopGraph(project: ProjectRef(path: "/tmp/p", name: "p"))
    graph.mailroom = [
      MailroomPost(
        id: 1, at: Date(), authorID: nil, author: "a human", topic: "claims", body: "taking #12")
    ]
    let data = try Self.rewritten(graph, [("mailroom", "artifactory")])
    let decoded = try JSONDecoder().decode(LoopGraph.self, from: data)
    #expect(decoded.mailroom.map(\.body) == ["taking #12"])
  }

  @Test
  func aLoopKeepsItsCursorAndItsWatch() throws {
    // A dropped cursor is not cosmetic: it re-delivers the whole board on the next
    // read, which is the ~45k-token first sync the triage rule exists to prevent.
    let node = LoopNode(
      title: "Worker", lastMailroomRead: 7, mailroomWatch: MailroomWatch(topic: "build"))
    let data = try Self.rewritten(
      node,
      [("lastMailroomRead", "lastArtifactoryRead"), ("mailroomWatch", "artifactoryWatch")])
    let decoded = try JSONDecoder().decode(LoopNode.self, from: data)
    #expect(decoded.lastMailroomRead == 7)
    #expect(decoded.mailroomWatch == MailroomWatch(topic: "build"))
  }

  @Test
  func postsKeepTheirKindUnderTheOldSpellings() throws {
    for (current, shipped, expected) in [
      ("letter", "record", MailroomPost.Kind.letter), ("notice", "note", .notice),
    ] {
      let post = MailroomPost(
        id: 1, at: Date(), authorID: nil, author: "a human", topic: nil, body: "b",
        kind: expected)
      let data = try Self.rewritten(post, [(current, shipped)])
      #expect(try JSONDecoder().decode(MailroomPost.self, from: data).kind == expected)
    }
  }

  @Test
  func anUnknownKindReadsAsANoticeRatherThanLosingTheBoard() throws {
    // ProjectPersistence turns any decode failure into "no saved graph", so throwing
    // here would trade one unreadable post for every post on the board.
    let post = MailroomPost(
      id: 1, at: Date(), authorID: nil, author: "a human", topic: nil, body: "b", kind: .letter)
    let data = try Self.rewritten(post, [("letter", "telegram")])
    #expect(try JSONDecoder().decode(MailroomPost.self, from: data).kind == .notice)
  }

  @Test
  func theKillSwitchStillAnswersUnderTheKeyItShippedWith() {
    // ramps.json is fetched from graphcode.app: a build that knew only the new key
    // would stop obeying the deployed file the moment it shipped ahead of it.
    let deployed = FeatureRamps.Configuration(features: ["artifactory": ["beta": 0, "stable": 0]])
    #expect(
      FeatureRamps.isEnabled(
        .mailroom, configuration: deployed, channel: "beta", installID: "any") == false)
    // And the new key wins wherever the file has caught up.
    let renamed = FeatureRamps.Configuration(features: [
      "artifactory": ["beta": 0, "stable": 0], "mailroom": ["beta": 100, "stable": 100],
    ])
    #expect(
      FeatureRamps.isEnabled(
        .mailroom, configuration: renamed, channel: "beta", installID: "any") == true)
  }

  @Test
  func everyVerbALiveLoopMayHaveBeenTaughtStillParses() throws {
    // A loop relaunched today carries whichever spelling its briefing was written
    // with, in its memory log and often mid-turn.
    for verb in ["mail", "mailroom", "artifactory"] {
      #expect(
        try GraphcodeCommand.parse([verb, "post", "/tmp/x", "hello"])
          == .mailroomPost(projectPath: "/tmp/x", topic: nil, text: "hello"))
    }
    for reader in ["inbox", "sync"] {
      #expect(
        try GraphcodeCommand.parse(["mail", reader, "/tmp/x"])
          == .mailroomInbox(
            projectPath: "/tmp/x", headlines: false, mark: false, json: false, full: false))
    }
  }
}
