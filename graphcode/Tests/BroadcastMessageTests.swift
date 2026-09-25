import ComposableArchitecture
import Foundation
import IdentifiedCollections
import Testing

@testable import GraphcodeKit
@testable import graphcode

/// Send Message to All Loops… (issue #375) — `GraphCommand.broadcastMessage` reaches every
/// loop in the graph: typed into each session that takes it, staged to the rest's memory.
@Suite
struct BroadcastMessageTests {
  private static let project = ProjectRef(path: "/tmp/broadcast", name: "broadcast")

  private func loop(_ title: String, _ state: LoopState) -> LoopNode {
    LoopNode(title: title, loopType: .goalBased, goal: GoalSpec(summary: "work"), state: state)
  }

  /// A finished loop whose session is still up takes `node send` (#346), and the
  /// broadcast used to skip it — and every other state it read as not live — without
  /// typing, staging, or counting it. Paused, blocked and mid-check loops are staged, as
  /// `node send` stages them, and finished ones are counted rather than named.
  @Test
  func everyLoopButTheSenderIsAddressed() async {
    let delivered = LockIsolated<[String: String]>([:])
    let memos = LockIsolated<[UUID: [String]]>([:])
    let errors = LockIsolated<[String]>([])
    let sender = loop("Sender", .running)
    let checking = loop("Checking", .awaitingInput)
    let graph = LoopGraph(
      project: Self.project,
      nodes: [
        sender, loop("Running", .running), loop("Idle", .idle), loop("Waiting", .waiting),
        loop("Done", .succeeded), loop("Failed", .failed), loop("Stalled", .stalled),
        loop("Stopped", .stopped), loop("Blocked", .blocked), checking,
      ])
    let store = GraphStore(
      graph: graph,
      onDeliverMessage: { node, message, _ in
        delivered.withValue { $0[node.title] = message }
        return true
      },
      onAppendMemory: { id, entry in memos.withValue { $0[id, default: []].append(entry) } },
      onAnnounceError: { message in errors.withValue { $0.append(message) } })

    await store.handle(.broadcastMessage(text: "  main is frozen  ", from: sender.id))

    #expect(Set(delivered.value.keys) == ["Running", "Idle", "Waiting", "Done", "Failed"])
    #expect(delivered.value["Done"] == "[graphcode] Sender: main is frozen")
    #expect(
      memos.value[checking.id] == ["while you were away: [graphcode] Sender: main is frozen"])
    #expect(memos.value.count == 4)
    #expect(memos.value[sender.id] == nil)
    #expect(errors.value.count == 1)
    #expect(errors.value.first?.contains("5 of 9") == true)
    #expect(errors.value.first?.contains("Blocked, Checking, 2 finished loops") == true)
  }

  /// `node send`'s recovery, per target: a live unattended loop whose session died is
  /// relaunched and typed into again; a finished one is staged, and a blocked one is
  /// never relaunched ahead of its upstream.
  @Test
  func aDeadUnattendedSessionIsRelaunchedAndRetried() async {
    let attempts = LockIsolated<[String: Int]>([:])
    let ensured = LockIsolated<[String]>([])
    let memos = LockIsolated<[UUID: [String]]>([:])
    let errors = LockIsolated<[String]>([])
    let crashed = loop("Crashed", .running)
    let done = loop("Done", .succeeded)
    let blocked = loop("Blocked", .blocked)
    let store = GraphStore(
      graph: LoopGraph(project: Self.project, nodes: [crashed, done, blocked]),
      onEnsureSession: { node, _ in ensured.withValue { $0.append(node.title) } },
      onDeliverMessage: { node, _, _ in
        let attempt = attempts.withValue { counts -> Int in
          counts[node.title, default: 0] += 1
          return counts[node.title] ?? 0
        }
        return node.id == crashed.id && attempt > 1
      },
      onAppendMemory: { id, entry in memos.withValue { $0[id, default: []].append(entry) } },
      onAnnounceError: { message in errors.withValue { $0.append(message) } })

    await store.handle(.broadcastMessage(text: "rebase", from: nil))

    #expect(ensured.value == ["Crashed"])
    #expect(attempts.value == ["Crashed": 2, "Done": 1])
    #expect(memos.value[crashed.id] == nil)
    #expect(memos.value[done.id] == ["while you were away: [graphcode] rebase"])
    #expect(memos.value[blocked.id] == ["while you were away: [graphcode] rebase"])
    #expect(errors.value.first?.contains("1 of 3") == true)
    #expect(errors.value.first?.contains("Blocked, 1 finished loop;") == true)
  }

  @Test
  func aFailedSendIsStagedToMemoryAndReportedOnce() async {
    let memos = LockIsolated<[String: [String]]>([:])
    let errors = LockIsolated<[String]>([])
    let reachable = loop("Reachable", .running)
    let gone = loop("Gone", .running)
    let alsoGone = loop("AlsoGone", .idle)
    let titles = [reachable.id: "Reachable", gone.id: "Gone", alsoGone.id: "AlsoGone"]
    let store = GraphStore(
      graph: LoopGraph(project: Self.project, nodes: [reachable, gone, alsoGone]),
      onDeliverMessage: { node, _, _ in node.id == reachable.id },
      onAppendMemory: { id, entry in
        memos.withValue { $0[titles[id] ?? "?", default: []].append(entry) }
      },
      onAnnounceError: { message in errors.withValue { $0.append(message) } })

    await store.handle(.broadcastMessage(text: "rebase on main", from: nil))

    #expect(memos.value["Reachable"] == nil)
    #expect(memos.value["Gone"] == ["while you were away: [graphcode] rebase on main"])
    #expect(memos.value["AlsoGone"]?.contains { $0.contains("rebase on main") } == true)
    #expect(errors.value.count == 1)
    #expect(errors.value.first?.contains("1 of 3") == true)
  }

  private func composite(
    _ title: String, _ workers: [LoopNode], pilot: PilotState = .piloted
  ) -> LoopNode {
    LoopNode(
      title: title, loopType: .composite,
      subGraph: LoopGraph(
        project: ProjectRef(path: "sub", name: "sub"),
        nodes: IdentifiedArray(uniqueElements: workers)),
      pilotState: pilot)
  }

  /// Review of PR #382: recursing through each composite's child store wrote a letter
  /// and raised a summary per level. One broadcast is one letter and one verdict.
  @Test
  func nestedCompositesGetOneLetterAndOneSummary() async {
    let delivered = LockIsolated<[String: String]>([:])
    let errors = LockIsolated<[String]>([])
    let failing: Set<String> = ["Top B", "Worker B", "Deep"]
    let graph = LoopGraph(
      project: Self.project,
      nodes: [
        loop("Top A", .running), loop("Top B", .idle),
        composite("Team 1", [loop("Worker A", .running), loop("Worker B", .running)]),
        composite(
          "Team 2", [loop("Worker C", .idle), composite("Inner", [loop("Deep", .running)])]),
      ])
    let store = GraphStore(
      graph: graph,
      onDeliverMessage: { node, _, path in
        delivered.withValue { $0[node.title] = path }
        return !failing.contains(node.title)
      },
      onAnnounceError: { message in errors.withValue { $0.append(message) } },
      onMailroomEnabled: { true })

    await store.handle(.broadcastMessage(text: "freeze", from: nil))

    #expect(
      Set(delivered.value.keys)
        == ["Top A", "Top B", "Worker A", "Worker B", "Worker C", "Deep"])
    #expect(Set(delivered.value.values) == [Self.project.path])
    #expect(await store.graph.mailroom.filter { $0.body == "@all: freeze" }.count == 1)
    #expect(errors.value.count == 1)
    #expect(errors.value.first?.contains("3 of 6") == true)
  }

  @Test
  func anUnpilotedCompositesWorkersHaveNoSessionToReach() async {
    let delivered = LockIsolated<[String]>([])
    let errors = LockIsolated<[String]>([])
    let store = GraphStore(
      graph: LoopGraph(
        project: Self.project,
        nodes: [
          composite("Template", [loop("Worker", .idle)], pilot: .notPiloted), loop("Top", .idle),
        ]),
      onDeliverMessage: { node, _, _ in
        delivered.withValue { $0.append(node.title) }
        return true
      },
      onAnnounceError: { message in errors.withValue { $0.append(message) } })

    await store.handle(.broadcastMessage(text: "hello", from: nil))

    #expect(delivered.value == ["Top"])
    #expect(errors.value.isEmpty)
  }

  @Test
  func anEmptyMessageIsRefused() async {
    let delivered = LockIsolated(0)
    let errors = LockIsolated<[String]>([])
    let store = GraphStore(
      graph: LoopGraph(project: Self.project, nodes: [loop("Running", .running)]),
      onDeliverMessage: { _, _, _ in
        delivered.withValue { $0 += 1 }
        return true
      },
      onAnnounceError: { message in errors.withValue { $0.append(message) } })

    await store.handle(.broadcastMessage(text: " \n ", from: nil))

    #expect(delivered.value == 0)
    #expect(errors.value.count == 1)
  }

  @Test
  @MainActor
  func theAppSendsItToEveryProjectWithALoop() async {
    let sent = LockIsolated<[DaemonCommand]>([])
    let live = LoopGraph(
      project: ProjectRef(path: "/tmp/live", name: "live"), nodes: [loop("A", .running)])
    let finished = LoopGraph(
      project: ProjectRef(path: "/tmp/finished", name: "finished"),
      nodes: [loop("B", .succeeded)])
    let empty = LoopGraph(project: ProjectRef(path: "/tmp/empty", name: "empty"), nodes: [])
    var initial = AppFeature.State()
    initial.projects.append(ProjectFeature.State(graph: ProjectFeature.holding(live)))
    initial.projects.append(ProjectFeature.State(graph: ProjectFeature.holding(finished)))
    initial.projects.append(ProjectFeature.State(graph: ProjectFeature.holding(empty)))
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.orchestratorClient.send = { command in sent.withValue { $0.append(command) } }
    }
    store.exhaustivity = .off

    await store.send(.sessionRestart(.broadcastTapped))
    #expect(store.state.sessionRestart.broadcastDraft == "")
    await store.send(.sessionRestart(.broadcastConfirmed))
    #expect(store.state.sessionRestart.broadcastDraft == "")
    await store.send(.sessionRestart(.broadcastDraftChanged(" ship it ")))
    await store.send(.sessionRestart(.broadcastConfirmed))
    await store.finish()

    #expect(store.state.sessionRestart.broadcastDraft == nil)
    #expect(
      sent.value == [
        .graphCommand(
          projectPath: "/tmp/live", command: .broadcastMessage(text: "ship it", from: nil)),
        .graphCommand(
          projectPath: "/tmp/finished", command: .broadcastMessage(text: "ship it", from: nil)),
      ])
  }
}
