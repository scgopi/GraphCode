import Foundation
import Testing

@testable import GraphcodeKit

@Suite
struct NodBackendTests {
  @Test
  func nodIsAChatSurfaceNamedInFullOnlyInSetup() {
    #expect(CLISessionBackendKind.nod.displayName == "Nod")
    #expect(CLISessionBackendKind.nod.fullName == "GraphCode Nod")
    #expect(CLISessionBackendKind.nod.surface == .chat)
    for kind in CLISessionBackendKind.allCases where kind != .nod {
      #expect(kind.surface == .terminal)
      #expect(kind.fullName == kind.displayName)
    }
  }

  @Test
  func theGoalIsAFieldNotADirective() {
    let row = CLISessionBackendKind.nod.capabilities
    #expect(row.goalDirective == nil)
    #expect(row.supportsGoalMode)
    #expect(row.supportsHooks)
    #expect(row.supportsSubAgents)
    #expect(row.supportsMidSessionInput)
    #expect(row.supportsDaemonRecurrence)
    #expect(!row.supportsInSessionRecurrence)
  }

  /// Until NodRuntime ships a binary, a loop labelled Nod would open nothing — the exact
  /// failure `isSpiked` exists to refuse.
  @Test
  func nodHostsNothingWhereItCannotLaunch() {
    // The test host never installs `NodRuntimeLocator.installAvailability`, so this is the
    // answer for a process with no ramp flag or runtime: only the override would count.
    #expect(NodRuntimeLocation.developmentOverride == nil)
    #expect(!CLISessionBackendKind.nod.isSpiked)
    #expect(CLISessionBackendKind.nod.executableName == "graphcode-nod")
    for loopType in LoopType.allCases {
      #expect(!CLISessionBackendKind.nod.canHost(loopType))
    }
    #expect(!CLISessionBackendKind.offerableAsDefault.contains(.nod))
    #expect(CLISessionBackend.backend(for: .nod).kind == .nod)
  }

  @Test
  func aStoredNodDefaultFallsBackToClaudeCode() {
    #expect(GraphcodeSettings(defaultBackend: .nod).defaultBackend == .claudeCode)
  }
}

@Suite
struct NodProtocolTests {
  private let at = Date(timeIntervalSince1970: 1_790_000_000)

  private func line(_ record: NodEventRecord) throws -> String {
    String(decoding: try NodProtocol.makeEncoder().encode(record), as: UTF8.self)
  }

  @Test
  func anEventIsOneFlatObjectDiscriminatedByType() throws {
    let record = NodEventRecord(
      seq: 7, at: at,
      event: .toolCall(.init(turn: 4, callID: "c1", tool: "Bash", title: "Shell swift test")))

    let json = try line(record)

    #expect(
      json
        == #"{"at":"2026-09-21T14:13:20Z","callID":"c1","seq":7,"title":"Shell swift test","#
        + #""tool":"Bash","turn":4,"type":"toolCall","v":1}"#)
  }

  @Test
  func everyEventRoundTrips() throws {
    let node = UUID()
    let events: [NodEvent] = [
      .sessionStarted(
        .init(engine: .copilotSDK, model: "gpt-5", conversationID: "s1", resumed: false)),
      .turnStarted(.init(turn: 1, origin: .handoff)),
      .userMessage(
        .init(
          id: "m1", text: "fix /export", delivery: .steer,
          attachments: [.init(kind: .loopTranscript, reference: node.uuidString)],
          fromNodeID: node)),
      .assistantText(.init(turn: 1, messageID: "a1", delta: "Found it.", final: true)),
      .toolResult(
        .init(callID: "c1", status: .ok, summary: "exit 0", output: "ok", durationMs: 14_000)),
      .hunkStaged(
        .init(
          turn: 1, hunkID: "h1", file: "Routes.swift", header: "@@ 41,6 @@", diff: "+x",
          added: 1, removed: 0, autoAccepted: false)),
      .hunkResolved(.init(hunkID: "h1", decision: .comment, note: "use 51")),
      .permissionAsked(
        .init(
          askID: "p1", kind: .network, subject: "swift package resolve", reason: "network",
          answerableFromCard: false)),
      .permissionResolved(.init(askID: "p1", decision: .allowOnce)),
      .goalCheck(
        .init(
          turn: 4, evaluatorModel: "haiku",
          clauses: [.init(text: "swift test passes", met: false, evidence: "1 failure")],
          met: false)),
      .turnEnded(.init(turn: 4, filesChanged: 2, added: 25, removed: 1, summary: "Moved it")),
      .usage(
        .init(
          inputTokens: 10, outputTokens: 5, costUSD: 0.02, premiumRequests: nil,
          contextUsed: 0.82)),
      .planProposed(
        .init(
          planID: "pl1", title: "Caps",
          steps: [.init(id: "1", text: "Move /export", files: ["Routes.swift"], size: .small)])),
      .mailDraft(.init(draftID: "d1", toNodeID: node, inReplyTo: "1174", text: "402")),
      .compacted(.init(fromTurn: 1, throughTurn: 9)),
      .activity(.init(line: "Running swift test · turn 4")),
      .failure(.init(kind: .spendCap, message: "hit its $2.00 cap")),
    ]

    for (seq, event) in events.enumerated() {
      let record = NodEventRecord(seq: seq, at: at, event: event)
      let decoded = try NodProtocol.makeDecoder().decode(
        NodEventRecord.self, from: Data(try line(record).utf8))
      #expect(decoded == record)
    }
  }

  /// An older app must keep reading a newer runtime's log rather than stop at the first
  /// event it has never heard of.
  @Test
  func anUnknownEventTypeDecodesInsteadOfThrowing() throws {
    let json = #"{"v":1,"seq":3,"at":"2026-09-21T14:13:20Z","type":"handoffOffered","to":"x"}"#

    let record = try NodProtocol.makeDecoder().decode(NodEventRecord.self, from: Data(json.utf8))

    #expect(record.event == .unknown("handoffOffered"))
  }

  @Test
  func aTornFinalLineIsSkipped() throws {
    let whole = try line(
      NodEventRecord(seq: 1, at: at, event: .activity(.init(line: "Reading Routes.swift"))))
    let log = Data((whole + "\n" + #"{"v":1,"seq":2,"at":"#).utf8)

    let records = NodProtocol.records(fromJSONLines: log)

    #expect(records.map(\.seq) == [1])
  }

  @Test
  func everyCommandRoundTrips() throws {
    let commands: [NodCommand] = [
      .send(.init(text: "use the fixture clock", delivery: .steer)),
      .stop,
      .resolveHunk(.init(hunkID: "h1", decision: .reject, note: "wrong file")),
      .resolvePermission(.init(askID: "p1", decision: .alwaysAllow)),
      .runPlan(
        .init(
          planID: "pl1", steps: [.init(id: "2", text: "mine", editedByHuman: true)],
          mode: .composite)),
      .fork(.init(messageID: "a1")),
      .sendDraft(.init(draftID: "d1", text: "402, body { limit, resetsAt }")),
      .compact,
      .setModel(.init(model: "opus")),
      .markGoalDone,
    ]

    for command in commands {
      let data = try NodProtocol.makeEncoder().encode(command)
      #expect(try NodProtocol.makeDecoder().decode(NodCommand.self, from: data) == command)
    }
    #expect(
      String(decoding: try NodProtocol.makeEncoder().encode(NodCommand.stop), as: UTF8.self)
        == #"{"type":"stop"}"#)
  }
}

@Suite
struct NodSettingsTests {
  @Test
  func anOlderSettingsFileGetsNodDefaults() throws {
    let settings = try JSONDecoder().decode(GraphcodeSettings.self, from: Data("{}".utf8))

    #expect(settings.nod == NodSettings())
    #expect(settings.nod.editsInWorktree == .auto)
    #expect(settings.nod.editsOutsideWorktree == .never)
    #expect(settings.nod.messagesOtherLoops == .draftForMe)
  }

  @Test
  func aPartialNodSectionKeepsTheRestAtDefaults() throws {
    let json =
      #"{"nod":{"engine":"copilot","modelsByLoopType":{"goalBased":"opus"},"spendCapUSD":0}}"#

    let nod = try JSONDecoder().decode(GraphcodeSettings.self, from: Data(json.utf8)).nod

    #expect(nod.engine == .copilotSDK)
    #expect(nod.model(for: .goalBased) == "opus")
    #expect(nod.model(for: .sketch) == nil)
    #expect(nod.spendCapUSD == 0)
    #expect(nod.shell == .ask)
  }

  @Test
  func nodSettingsRoundTrip() throws {
    var settings = GraphcodeSettings()
    settings.nod.shellAllowlist = ["swift test *", "make lint"]
    settings.nod.network = .always

    let data = try JSONEncoder().encode(settings)

    #expect(try JSONDecoder().decode(GraphcodeSettings.self, from: data) == settings)
  }
}
