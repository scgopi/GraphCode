import ComposableArchitecture
import Foundation
import Testing

@testable import GraphcodeKit
@testable import graphcode

#if canImport(Darwin)
  import Darwin
#endif

private let start = Date(timeIntervalSince1970: 1_790_000_000)

private func records(_ events: [NodEvent]) -> [NodEventRecord] {
  events.enumerated().map {
    NodEventRecord(
      seq: $0.offset + 1, at: start.addingTimeInterval(Double($0.offset)), event: $0.element)
  }
}

private let started = NodEvent.sessionStarted(
  .init(engine: .claudeAgentSDK, model: "sonnet", conversationID: "conv-1", resumed: false))

private func ask(_ id: String, fromCard: Bool = false) -> NodEvent {
  .permissionAsked(
    .init(
      askID: id, kind: .network, subject: "swift package resolve", reason: "network",
      answerableFromCard: fromCard))
}

@Suite
struct NodSessionFoldTests {
  @Test
  func turnBoundariesSayBusyThenIdle() {
    var fold = NodSessionFold(records: records([started]))
    #expect(fold.presence == .idle)
    fold = NodSessionFold(records: records([started, .turnStarted(.init(turn: 1, origin: .user))]))
    #expect(fold.presence == .busy)
    fold = NodSessionFold(
      records: records([
        started, .turnStarted(.init(turn: 1, origin: .user)),
        .turnEnded(.init(turn: 1, filesChanged: 0, added: 0, removed: 0, summary: nil)),
      ]))
    #expect(fold.presence == .idle)
    #expect(NodSessionFold().presence == nil)
  }

  @Test
  func anOpenAskIsNeedsYouUntilItIsAnswered() {
    let asked = records([started, .turnStarted(.init(turn: 1, origin: .user)), ask("a1")])
    let fold = NodSessionFold(records: asked)
    #expect(fold.presence == .awaitingInput)
    #expect(fold.activityLine == "asks to run swift package resolve")
    #expect(fold.cardState.pendingAsk?.askID == "a1")
    #expect(fold.cardState.pendingAsk?.answerableFromCard == false)

    let answered = NodSessionFold(
      records: records([
        started, .turnStarted(.init(turn: 1, origin: .user)), ask("a1"),
        .permissionResolved(.init(askID: "a1", decision: .allowOnce)),
      ]))
    #expect(answered.presence == .busy)
    #expect(answered.cardState.pendingAsk == nil)
  }

  /// A new run is a new process: an ask the last one left open asks nothing of anybody.
  @Test
  func aNewRunForgetsTheLastRunsAsksAndSpend() {
    let fold = NodSessionFold(
      records: records([
        started, ask("a1"),
        .usage(.init(inputTokens: 10, outputTokens: 2, contextUsed: 0.1)),
        started,
      ]))
    #expect(fold.presence == .idle)
    #expect(fold.openAsks.isEmpty)
    #expect(fold.usageSample == nil)
  }

  @Test
  func failuresAreNeedsYouExceptAFullContext() {
    func presence(after kind: NodFailureKind) -> Presence? {
      NodSessionFold(
        records: records([
          started, .turnStarted(.init(turn: 1, origin: .user)),
          .failure(.init(kind: kind, message: "stopped")),
        ])
      ).presence
    }
    #expect(presence(after: .signInExpired) == .awaitingInput)
    #expect(presence(after: .spendCap) == .awaitingInput)
    #expect(presence(after: .permissionUnavailable) == .awaitingInput)
    #expect(presence(after: .engineError) == .awaitingInput)
    #expect(presence(after: .contextFull) == .busy)

    let resumed = NodSessionFold(
      records: records([
        started, .failure(.init(kind: .signInExpired, message: "expired")),
        .turnStarted(.init(turn: 2, origin: .user)),
      ]))
    #expect(resumed.presence == .busy)
  }

  @Test
  func theLiveLineFollowsToolsUntilTheyFinish() {
    let call = NodEvent.toolCall(
      .init(turn: 1, callID: "c1", tool: "Grep", title: "Search \"UsageGate\""))
    var events: [NodEvent] = [started, .turnStarted(.init(turn: 1, origin: .user)), call]
    #expect(NodSessionFold(records: records(events)).activityLine == "Search \"UsageGate\"")
    events.append(.toolResult(.init(callID: "c1", status: .ok, summary: "6 hits")))
    #expect(NodSessionFold(records: records(events)).activityLine == nil)
    events.append(.activity(.init(line: "Running swift test · turn 1")))
    events.append(.toolResult(.init(callID: "c9", status: .ok, summary: "")))
    #expect(NodSessionFold(records: records(events)).activityLine == "Running swift test · turn 1")
    events.append(.turnEnded(.init(turn: 1, filesChanged: 1, added: 3, removed: 1, summary: nil)))
    #expect(NodSessionFold(records: records(events)).activityLine == nil)
  }

  @Test
  func usageIsTheNewestRunningTotal() {
    let fold = NodSessionFold(
      records: records([
        started,
        .usage(.init(inputTokens: 10, outputTokens: 2, costUSD: 0.01, contextUsed: 0.1)),
        .usage(.init(inputTokens: 30, outputTokens: 5, costUSD: 0.04, contextUsed: 0.2)),
      ]))
    #expect(
      fold.usageSample
        == UsageSample(
          inputTokens: 30, outputTokens: 5, costUSD: 0.04, reportedAt: start.addingTimeInterval(2)))
  }

  @Test
  func theNewestGoalCheckIsTheVerdictAndTheProgress() {
    func check(_ met: [Bool]) -> NodEvent {
      .goalCheck(
        .init(
          turn: 1, evaluatorModel: "haiku",
          clauses: met.enumerated().map { NodGoalClause(text: "c\($0.offset)", met: $0.element) },
          met: met.allSatisfy { $0 }))
    }
    let notYet = NodSessionFold(records: records([started, check([true, false])]))
    #expect(notYet.goalVerdict?.met == false)
    #expect(notYet.cardState.goalProgress == NodGoalProgress(met: 1, total: 2))

    let met = NodSessionFold(
      records: records([started, check([true, false]), check([true, true])]))
    #expect(met.goalVerdict?.met == true)
    #expect(met.goalVerdict?.detail == "2 of 2 clauses met")
    #expect(met.goalVerdict?.recordedAt == start.addingTimeInterval(2))
    #expect(NodSessionFold(records: records([started])).goalVerdict == nil)
  }

  @Test
  func unknownEventsChangeNothing() {
    let known = NodSessionFold(
      records: records([started, .turnStarted(.init(turn: 1, origin: .user))]))
    var withUnknown = known
    withUnknown.apply(NodEventRecord(seq: 3, at: start, event: .unknown("fromTheFuture")))
    #expect(withUnknown.presence == known.presence)
    #expect(withUnknown.activityLine == known.activityLine)
  }
}

@Suite
struct NodSessionLogTests {
  @Test
  func readsTheLogSkippingATornLastLine() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("nod-\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: url) }
    let encoder = NodProtocol.makeEncoder()
    var data = Data()
    for record in records([started, .turnStarted(.init(turn: 1, origin: .user))]) {
      data.append(try encoder.encode(record))
      data.append(UInt8(ascii: "\n"))
    }
    data.append(Data(#"{"v":1,"seq":3,"at":"2026-"#.utf8))
    try data.write(to: url)
    let read = NodSessionLog.records(inLogAt: url)
    #expect(read.map(\.seq) == [1, 2])
    #expect(NodSessionFold(records: read).presence == .busy)
  }

  @Test
  func summaryBeatsComeFromTurnsNarrationAndTools() {
    let reading = NodSessionLog.reading(
      of: records([
        started,
        .turnStarted(.init(turn: 1, origin: .user)),
        .assistantText(
          .init(turn: 1, messageID: "m1", delta: "Found it. ExportRoute ", final: false)),
        .assistantText(
          .init(
            turn: 1, messageID: "m1", delta: "is registered before UsageGate runs.", final: true)),
        .toolCall(.init(turn: 1, callID: "c1", tool: "Read", title: "Read UsageGate.swift")),
        .turnEnded(.init(turn: 1, filesChanged: 0, added: 0, removed: 0, summary: nil)),
      ]), metricSamples: [])
    #expect(!reading.isEmpty)
    #expect(reading.turns == [start.addingTimeInterval(1)])
    #expect(reading.closing?.contains("ExportRoute is registered before UsageGate runs.") == true)
  }
}

@Suite(.serialized)
struct NodLaunchArgumentTests {
  private let nodeID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

  /// A pane can start a Nod session before the daemon does; it must launch it the same way —
  /// the lineage brief on a fresh start only, and a composite child unattended.
  @Test
  func aPaneStartedNodLoopCarriesItsLineageLikeTheDaemon() throws {
    NodRuntimeLocator.binaryOverride = URL(fileURLWithPath: "/r/graphcode-nod")
    NodRuntimeLocator.rampOverride = true
    defer {
      NodRuntimeLocator.binaryOverride = nil
      NodRuntimeLocator.rampOverride = nil
    }
    let pane = GhosttyTerminalView(
      surfaceID: UUID(),
      sessionName: SurfaceRef(id: nodeID, launchesClaudeCode: true).zmxSessionName,
      launchesClaudeCode: true, backend: .nod, loopType: .goalBased,
      lineage: LoopLineage(
        kind: .compositeChild, sourceNodeID: UUID(), briefPath: "/briefs/child.json"),
      workingDirectory: nil, onProcessExited: { _ in })

    let fresh = try #require(pane.launchPrefix(settings: GraphcodeSettings()))
    let resumed = try #require(pane.launchPrefix(settings: GraphcodeSettings(), fresh: false))

    #expect(fresh.contains("'--inherit'"))
    #expect(fresh.contains("'/briefs/child.json'"))
    #expect(fresh.contains("'--unattended'"))
    #expect(!resumed.contains("'--inherit'"))
    #expect(resumed.contains("'--unattended'"))
  }

  @Test
  func theRuntimeTakesItsPromptAndBriefingByFlag() {
    let nod = CLISessionBackendKind.nod
    #expect(
      nod.launchArguments(prompt: "fix the cap", tier: .standard, briefingPath: "/b/AGENTS.md")
        == ["--briefing", "/b/AGENTS.md", "--prompt", "fix the cap"])
    #expect(nod.launchArguments(prompt: nil, tier: .standard) == [])
    #expect(nod.resumeArguments(sessionID: "conv-1") == ["--resume", "conv-1"])
    #expect(nod.supportsResume)
    #expect(nod.promptFlag == "--prompt")
    #expect(nod.recordsGoalVerdict)
  }

  @Test
  func nodArgumentsNameTheNodeEngineLoopTypeAndModel() {
    var settings = GraphcodeSettings()
    settings.nod.engine = .copilotSDK
    settings.nod.modelsByLoopType = [LoopType.goalBased.rawValue: "opus"]
    #expect(
      CLISessionBackendKind.nod.nodArguments(
        nodeID: nodeID, loopType: .goalBased, settings: settings, workingDirectory: "/w",
        goalFile: "/s/goal.md")
        == [
          "--node", nodeID.uuidString, "--cwd", "/w", "--engine", "copilot", "--loop-type", "goal",
          "--model", "opus", "--goal-file", "/s/goal.md",
        ])
    #expect(
      CLISessionBackendKind.nod.nodArguments(
        nodeID: nodeID, loopType: .sketch, settings: GraphcodeSettings())
        == ["--node", nodeID.uuidString, "--engine", "claude", "--loop-type", "main"])
    for kind in CLISessionBackendKind.allCases where kind != .nod {
      #expect(kind.nodArguments(nodeID: nodeID, loopType: .goalBased, settings: settings).isEmpty)
    }
    #expect(LoopType.timeBased.nodArgument == "timed")
    #expect(LoopType.turnBased.nodArgument == "turn")
    #expect(LoopType.composite.nodArgument == "composite")
  }

  @Test
  func theDaemonLaunchesTheBundledRuntimeWithItsStateDirectory() throws {
    NodRuntimeLocator.binaryOverride = URL(fileURLWithPath: "/Apps/GraphCode.app/bin/graphcode-nod")
    NodRuntimeLocator.rampOverride = true
    defer {
      NodRuntimeLocator.binaryOverride = nil
      NodRuntimeLocator.rampOverride = nil
    }
    let node = LoopNode(
      id: nodeID, title: "Cap", loopType: .turnBased, checkDescription: "tests pass",
      backend: .nod)
    let arguments = try #require(
      ZmxSessionLauncher.arguments(forNode: node, settings: GraphcodeSettings()))
    #expect(Array(arguments.prefix(3)) == ["run", "graphcode-\(nodeID.uuidString)", "-d"])
    let script = arguments[7]
    let state = NodRuntimeLocator.stateDirectory(forNodeID: nodeID).path
    #expect(
      script.hasPrefix(
        "exec env NOD_NODE_ID=\"\(nodeID.uuidString)\" NOD_STATE=\"\(state)\" "
          + "/Apps/GraphCode.app/bin/graphcode-nod "))
    let argv = Array(arguments.dropFirst(9))
    #expect(
      Array(argv.prefix(6)) == [
        "--node", nodeID.uuidString, "--engine", "claude", "--loop-type", "turn",
      ])
    #expect(argv.suffix(2).first == "--prompt")

    let resume = try #require(
      ZmxSessionLauncher.resumeArguments(
        forNode: node, sessionID: "conv-1", settings: GraphcodeSettings()))
    #expect(resume[7] == script)
    #expect(Array(resume.suffix(2)) == ["--resume", "conv-1"])
    #expect(!resume.contains("--prompt"))
  }

  @Test
  func aTimedLoopIsUnattendedAndTheEnvironmentNamesItsProject() {
    var timed = LoopNode(
      id: nodeID, title: "Nightly", loopType: .timeBased, triggerPrompt: "/loop 1h deps",
      backend: .nod)
    timed.lineage = LoopLineage(kind: .fork, sourceNodeID: UUID(), briefPath: "/b.md")
    let argv = ZmxSessionLauncher.nodArguments(
      forNode: timed, projectPath: nil, settings: GraphcodeSettings())
    #expect(Array(argv.suffix(3)) == ["--inherit", "/b.md", "--unattended"])
    let goal = LoopNode(id: nodeID, title: "Cap", loopType: .turnBased, backend: .nod)
    #expect(
      !ZmxSessionLauncher.nodArguments(
        forNode: goal, projectPath: nil, settings: GraphcodeSettings()
      )
      .contains("--unattended"))
    #expect(
      NodRuntimeLocator.environment(forNodeID: nodeID, projectPath: "/p")
        == [
          "NOD_STATE": NodRuntimeLocator.stateDirectory(forNodeID: nodeID).path,
          "NOD_NODE_ID": nodeID.uuidString, "NOD_PROJECT_PATH": "/p",
        ])
  }

  /// A brief is what a fresh conversation starts from; a resumed one already has it, and
  /// sending it again would replay the handoff as a new turn.
  @Test
  func theLineageBriefRidesAFreshLaunchOnly() {
    var child = LoopNode(id: nodeID, title: "Server caps", loopType: .goalBased, backend: .nod)
    child.lineage = LoopLineage(
      kind: .compositeChild, sourceNodeID: UUID(), briefPath: "/briefs/child.json")

    let fresh = ZmxSessionLauncher.nodArguments(
      forNode: child, projectPath: nil, settings: GraphcodeSettings())
    let resumed = ZmxSessionLauncher.nodArguments(
      forNode: child, projectPath: nil, settings: GraphcodeSettings(), fresh: false)

    #expect(Array(fresh.suffix(3)) == ["--inherit", "/briefs/child.json", "--unattended"])
    #expect(!resumed.contains("--inherit"))
    #expect(resumed.last == "--unattended")
    #expect(NodRuntimeLocator.environment(forNodeID: nodeID)["NOD_PROJECT_PATH"] == nil)
  }

  @Test
  func aMainLoopWithNothingToSayStillLaunches() throws {
    NodRuntimeLocator.binaryOverride = URL(fileURLWithPath: "/r/graphcode-nod")
    NodRuntimeLocator.rampOverride = true
    defer {
      NodRuntimeLocator.binaryOverride = nil
      NodRuntimeLocator.rampOverride = nil
    }
    let node = LoopNode(id: nodeID, title: "Chat", loopType: .sketch, backend: .nod)
    let arguments = try #require(
      ZmxSessionLauncher.arguments(forNode: node, settings: GraphcodeSettings()))
    #expect(
      Array(arguments.dropFirst(9))
        == ["--node", nodeID.uuidString, "--engine", "claude", "--loop-type", "main"])
    // A CLI with nothing to say still gets no argv — that path is unchanged.
    #expect(
      ZmxSessionLauncher.arguments(forNode: LoopNode(title: "Chat", loopType: .sketch)) == nil)
  }

  @Test
  func noRuntimeMeansNoLaunchAndARemoteProjectHasNone() {
    NodRuntimeLocator.binaryOverride = nil
    let node = LoopNode(id: nodeID, title: "Chat", loopType: .sketch, backend: .nod)
    if NodRuntimeLocator.binaryURL() == nil {
      #expect(ZmxSessionLauncher.arguments(forNode: node, settings: GraphcodeSettings()) == nil)
    }
    NodRuntimeLocator.binaryOverride = URL(fileURLWithPath: "/r/graphcode-nod")
    NodRuntimeLocator.rampOverride = true
    defer {
      NodRuntimeLocator.binaryOverride = nil
      NodRuntimeLocator.rampOverride = nil
    }
    #expect(ZmxSessionLauncher.executable(forNode: node, projectPath: "ssh://host/repo") == nil)
  }

  /// The ramp is the kill switch: off, nothing launches even with a runtime in hand.
  @Test
  func theRampTurnedOffLaunchesNothing() {
    NodRuntimeLocator.binaryOverride = URL(fileURLWithPath: "/r/graphcode-nod")
    NodRuntimeLocator.rampOverride = false
    defer {
      NodRuntimeLocator.binaryOverride = nil
      NodRuntimeLocator.rampOverride = nil
    }
    let node = LoopNode(id: nodeID, title: "Chat", loopType: .sketch, backend: .nod)
    #expect(NodRuntimeLocator.binaryURL() == nil)
    #expect(ZmxSessionLauncher.arguments(forNode: node, settings: GraphcodeSettings()) == nil)
  }

  @Test
  func theAppMirrorsTheRampIntoTheFlagTheDaemonReads() throws {
    let flag = FileManager.default.temporaryDirectory
      .appendingPathComponent("nod-\(UUID().uuidString)/ramp.on")
    defer { try? FileManager.default.removeItem(at: flag.deletingLastPathComponent()) }
    FeatureRamps.publishNodFlag(enabled: true, flag: flag)
    #expect(FileManager.default.fileExists(atPath: flag.path))
    FeatureRamps.publishNodFlag(enabled: false, flag: flag)
    #expect(!FileManager.default.fileExists(atPath: flag.path))
  }

  @Test
  func theCLIAndTheDaemonRefuseNodWhileTheRampIsOff() async throws {
    NodRuntimeLocator.rampOverride = false
    defer { NodRuntimeLocator.rampOverride = nil }
    let draft = NodeDraft(title: "Chat", loopType: .sketch, backend: .nod)
    let store = GraphStore()
    let result = await store.handle(.createNode(draft))
    if case .rejected(let message, _) = result {
      #expect(message.contains("GraphCode Nod is not enabled"))
    } else {
      Issue.record("expected a refusal, got \(result)")
    }
    #expect(await store.graph.nodes.isEmpty)
    #expect(
      throws: GraphcodeCommand.ParseError.nodNotEnabled,
      performing: {
        try GraphcodeCommand.parse([
          "node", "create", "/p", "--title", "Chat", "--type", "main", "--backend", "nod",
        ])
      })
    #expect(
      GraphcodeCommand.describe(.nodNotEnabled)
        == "refused: GraphCode Nod is not enabled on this install yet")
  }

  @Test
  func aGoalLoopsConditionIsWrittenWhereGoalFilePoints() throws {
    let node = LoopNode(
      id: UUID(), title: "Cap", loopType: .goalBased,
      goal: GoalSpec(summary: "Every paid route goes through UsageGate"), backend: .nod)
    let file = try #require(NodRuntimeLocator.writeGoal(of: node))
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    #expect(file.lastPathComponent == "goal.md")
    #expect(
      try String(contentsOf: file, encoding: .utf8) == "Every paid route goes through UsageGate")
    #expect(NodRuntimeLocator.writeGoal(of: LoopNode(title: "t", backend: .nod)) == nil)
  }

  /// Nod is not on the login shell's PATH, so a headless call that names it bare never
  /// runs: a blank-titled Nod loop stayed "NewNode", and every summary rewrite failed.
  @Test
  func headlessRequestsRunTheBundledRuntimeByPath() throws {
    NodRuntimeLocator.binaryOverride = URL(fileURLWithPath: "/Apps/Graph Code.app/nod/graphcode-nod")
    NodRuntimeLocator.rampOverride = true
    defer {
      NodRuntimeLocator.binaryOverride = nil
      NodRuntimeLocator.rampOverride = nil
    }
    let title = try #require(TitleSuggestionClient.invocation(for: .nod)?.last)
    #expect(
      title == "exec '/Apps/Graph Code.app/nod/graphcode-nod' -p \"$GRAPHCODE_TITLE_PROMPT\"")
    let summary = SummaryModelWriter.invocation(forBackend: .nod, prompt: "p")
    #expect(Array(summary.prefix(3)) == ["/Apps/Graph Code.app/nod/graphcode-nod", "-p", "p"])
  }

  @Test
  func noRuntimeMeansNoTitleRequest() {
    NodRuntimeLocator.rampOverride = false
    defer { NodRuntimeLocator.rampOverride = nil }
    #expect(TitleSuggestionClient.invocation(for: .nod) == nil)
  }
}

private func failure(of result: Result<Void, NodControlClient.Failure>)
  -> NodControlClient.Failure?
{
  if case .failure(let failure) = result { return failure }
  return nil
}

@Suite
struct NodControlClientTests {
  @Test
  func repliesAreOkOrARefusalWithItsReason() {
    #expect(failure(of: NodControlClient.parseReply(Data(#"{"ok":true}"#.utf8))) == nil)
    #expect(
      failure(of: NodControlClient.parseReply(Data(#"{"ok":false,"error":"busy"}"#.utf8)))
        == .refused("busy"))
    #expect(failure(of: NodControlClient.parseReply(Data("nope".utf8))) == .malformedReply)
  }

  @Test
  func aMissingSocketIsUnreachableSoTheCallerTypesInstead() async {
    let result = await NodControlClient.send(
      .send(.init(text: "hi")), socketPath: "/tmp/nod-\(UUID().uuidString).sock")
    #expect(failure(of: result) == .unreachable)
  }

  #if canImport(Darwin)
    /// A real socket: the line the runtime reads is one queued `send`, and its answer is
    /// what the caller gets back.
    @Test
    func sendsOneQueuedLineAndReadsTheAnswer() async throws {
      let path = "/tmp/nod-\(UUID().uuidString.prefix(8)).sock"
      let server = try OneShotUnixServer(path: path, reply: #"{"ok":true}"# + "\n")
      defer { server.close() }
      let result = await NodControlClient.send(.send(.init(text: "ship it")), socketPath: path)
      #expect(failure(of: result) == nil)
      let line = try #require(server.received())
      let command = try NodProtocol.makeDecoder().decode(NodCommand.self, from: Data(line.utf8))
      #expect(command == .send(.init(text: "ship it", delivery: .queue)))
    }
  #endif
}

#if canImport(Darwin)
  /// Accepts one connection, records one line, answers with `reply`.
  private final class OneShotUnixServer: @unchecked Sendable {
    private let descriptor: Int32
    private let path: String
    private let done = DispatchSemaphore(value: 0)
    private var line: String?

    init(path: String, reply: String) throws {
      self.path = path
      unlink(path)
      descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
      var address = sockaddr_un()
      address.sun_family = sa_family_t(AF_UNIX)
      withUnsafeMutablePointer(to: &address.sun_path) { field in
        field.withMemoryRebound(to: CChar.self, capacity: 104) { pointer in
          _ = path.withCString { strncpy(pointer, $0, 103) }
        }
      }
      let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
      }
      guard bound == 0, listen(descriptor, 1) == 0 else { throw POSIXError(.EADDRINUSE) }
      let listener = descriptor
      Thread.detachNewThread { [self] in
        let client = accept(listener, nil, nil)
        var bytes = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 256)
        while !bytes.contains(UInt8(ascii: "\n")) {
          let count = read(client, &buffer, buffer.count)
          guard count > 0 else { break }
          bytes += buffer[0..<count]
        }
        line = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .newlines)
        _ = reply.withCString { write(client, $0, strlen($0)) }
        Darwin.close(client)
        done.signal()
      }
    }

    func received() -> String? {
      _ = done.wait(timeout: .now() + 5)
      return line
    }

    func close() {
      Darwin.close(descriptor)
      unlink(path)
    }
  }
#endif

@Suite
struct NodGraphStoreTests {
  private func store(
    _ nodes: [LoopNode], verdict: GoalVerdict? = nil, presence: Presence = .idle
  ) -> GraphStore {
    var graph = LoopGraph(project: ProjectRef(path: "", name: "p"))
    for node in nodes { graph.nodes.append(node) }
    return GraphStore(
      graph: graph,
      onReadActivity: { _, _ in "asks to run swift package resolve" },
      onReadPresence: { _, _ in PresenceReading(presence: presence, confidence: .reported) },
      onReadGoalVerdict: { _, _ in verdict })
  }

  /// Nod's goal has no directive, which used to mean no verdict poller at all: the loop
  /// met its goal and ran on.
  @Test
  func aNodGoalLoopIsResolvedByItsRecordedVerdict() async {
    let node = LoopNode(
      title: "Cap", loopType: .goalBased,
      goal: GoalSpec(summary: "Every paid route is gated", pollIntervalSeconds: 1),
      backend: .nod, state: .running)
    let store = store([node], verdict: GoalVerdict(met: true, detail: "1 of 1 clauses met"))
    await store.ensureUnattendedSessions()
    for _ in 0..<40 where await store.graph.nodes[id: node.id]?.state != .succeeded {
      try? await Task.sleep(for: .milliseconds(100))
    }
    let resolved = await store.graph.nodes[id: node.id]
    #expect(resolved?.state == .succeeded)
    #expect(resolved?.resolution?.basis == .nativeGoal)
    #expect(resolved?.resolution?.detail == "1 of 1 clauses met")
  }

  /// A chat pane has no terminal whose attach would start a session, so opening a Nod loop
  /// asks for one. A terminal backend's loop is left to its pane.
  @Test
  func openingAChatLoopStartsItsSessionOnlyWhenNoneIsRunning() async {
    let nod = LoopNode(title: "Nod", loopType: .sketch, backend: .nod)
    let claude = LoopNode(title: "Claude", loopType: .sketch)
    let started = LockIsolated<[UUID]>([])
    let alive = LockIsolated(false)
    var graph = LoopGraph(project: ProjectRef(path: "", name: "p"))
    graph.nodes.append(contentsOf: [nod, claude])
    let store = GraphStore(
      graph: graph,
      onEnsureSession: { node, _ in started.withValue { $0.append(node.id) } },
      onSessionAlive: { _, _ in alive.value })

    await store.handle(.resumeSession(claude.id))
    await store.handle(.resumeSession(nod.id))
    alive.setValue(true)
    await store.handle(.resumeSession(nod.id))

    #expect(started.value == [nod.id])
  }

  @Test
  func aNodLoopWaitingOnAHumanSaysWhatItAsks() async {
    let nod = LoopNode(title: "Nod", loopType: .turnBased, backend: .nod, state: .running)
    let claude = LoopNode(title: "Claude", loopType: .turnBased, state: .running)
    let store = store([nod, claude], presence: .awaitingInput)
    await store.handle(.refreshUsage)
    let graph = await store.graph
    #expect(graph.nodes[id: nod.id]?.activity == "asks to run swift package resolve")
    #expect(graph.nodes[id: claude.id]?.activity == nil)
  }
}

#if os(macOS)
  /// `graphcoded` runs from the support directory with no bundle of its own, so a Nod loop
  /// it launches can only find the runtime the app copied there.
  @Suite
  struct NodRuntimeInstallTests {
    private func makeApp(withNod: Bool) throws -> URL {
      let app = FileManager.default.temporaryDirectory
        .appendingPathComponent("nod-\(UUID().uuidString).app", isDirectory: true)
      let bin = app.appendingPathComponent("Contents/Resources/bin", isDirectory: true)
      try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
      for name in ["graphcoded", "zmx", "graphcode"] {
        FileManager.default.createFile(
          atPath: bin.appendingPathComponent(name).path, contents: Data(name.utf8),
          attributes: [.posixPermissions: 0o755])
      }
      if withNod {
        let nod = app.appendingPathComponent(NodRuntimeLocator.bundledDirectory)
        try FileManager.default.createDirectory(at: nod, withIntermediateDirectories: true)
        FileManager.default.createFile(
          atPath: nod.appendingPathComponent("graphcode-nod").path, contents: Data("nod".utf8),
          attributes: [.posixPermissions: 0o755])
        FileManager.default.createFile(
          atPath: nod.appendingPathComponent("runtime.node").path, contents: Data("rt".utf8))
      }
      return app
    }

    @Test
    func theWholeRuntimeDirectoryIsCopiedBesideTheHelpers() throws {
      let app = try makeApp(withNod: true)
      let destination = FileManager.default.temporaryDirectory
        .appendingPathComponent("nod-bin-\(UUID().uuidString)", isDirectory: true)
      defer {
        try? FileManager.default.removeItem(at: app)
        try? FileManager.default.removeItem(at: destination)
      }
      let bundled = app.appendingPathComponent("Contents/Resources/bin")
      #expect(!DaemonBootstrap.nodRuntimeInstalled(from: bundled, in: destination))
      #expect(DaemonBootstrap.stamp(forHelpersIn: bundled).contains("\nnod:"))

      try DaemonBootstrap.installHelpers(from: bundled, to: destination)

      let installed = destination.appendingPathComponent("nod/graphcode-nod")
      #expect(FileManager.default.isExecutableFile(atPath: installed.path))
      #expect(
        FileManager.default.fileExists(
          atPath: destination.appendingPathComponent("nod/runtime.node").path))
      let type = try FileManager.default.attributesOfItem(atPath: installed.path)[.type]
      #expect(type as? FileAttributeType == .typeRegular)
      #expect(DaemonBootstrap.nodRuntimeInstalled(from: bundled, in: destination))

      try DaemonBootstrap.installHelpers(from: bundled, to: destination)
      #expect(FileManager.default.isExecutableFile(atPath: installed.path))
    }

    @Test
    func aBundleWithoutNodStillInstallsAndOwesNothing() throws {
      let app = try makeApp(withNod: false)
      let destination = FileManager.default.temporaryDirectory
        .appendingPathComponent("nod-bin-\(UUID().uuidString)", isDirectory: true)
      defer {
        try? FileManager.default.removeItem(at: app)
        try? FileManager.default.removeItem(at: destination)
      }
      let bundled = app.appendingPathComponent("Contents/Resources/bin")
      #expect(!DaemonBootstrap.stamp(forHelpersIn: bundled).contains("nod:"))
      try DaemonBootstrap.installHelpers(from: bundled, to: destination)
      #expect(DaemonBootstrap.nodRuntimeInstalled(from: bundled, in: destination))
      #expect(
        !FileManager.default.fileExists(atPath: destination.appendingPathComponent("nod").path))
    }
  }
#endif
