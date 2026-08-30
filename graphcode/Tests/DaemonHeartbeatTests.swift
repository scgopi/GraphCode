import ComposableArchitecture
import Foundation
import Testing

@testable import GraphcodeKit

/// The daemon-heartbeat experiment: a time-based loop the *daemon* ticks, behind
/// `GraphcodeSettings.daemonHeartbeatEnabled`, default off. Ticks are driven directly
/// (`deliverHeartbeat`) the way goal polling is — the timer is a sleep loop around
/// exactly this call.
@Suite
struct DaemonHeartbeatTests {
  private func heartbeatGraph(presence: Presence? = .idle) -> LoopGraph {
    LoopGraph(
      project: ProjectRef(path: "/tmp/heartbeat", name: "heartbeat"),
      nodes: [
        LoopNode(
          title: "Watcher", loopType: .timeBased,
          triggerPrompt: "check for new crash reports",
          heartbeatIntervalSeconds: 300,
          presence: presence.map { PresenceReading(presence: $0, confidence: .reported) },
          state: .running)
      ])
  }

  @Test
  func theToggleOffMeansNoBeatEverFires() async {
    let delivered = LockIsolated(0)
    let graph = heartbeatGraph()
    let store = GraphStore(
      graph: graph,
      onDeliverMessage: { _, _, _ in
        delivered.withValue { $0 += 1 }
        return true
      },
      onHeartbeatEnabled: { false })

    await store.deliverHeartbeat(graph.nodes[0].id)

    #expect(delivered.value == 0)
  }

  @Test
  func aBeatDeliversTheTaskToAnIdleSession() async {
    let delivered = LockIsolated<[String]>([])
    let graph = heartbeatGraph()
    let store = GraphStore(
      graph: graph,
      onDeliverMessage: { _, message, _ in
        delivered.withValue { $0.append(message) }
        return true
      },
      onHeartbeatEnabled: { true })

    await store.deliverHeartbeat(graph.nodes[0].id)

    #expect(delivered.value.count == 1)
    #expect(delivered.value[0].contains("Heartbeat"))
    #expect(delivered.value[0].contains("check for new crash reports"))
  }

  @Test
  func aBusySessionIsSkippedNotQueued() async {
    // Missed ticks coalesce: an agent mid-pass told to start a pass is the
    // double-driving this experiment must not reintroduce.
    let delivered = LockIsolated(0)
    let presence = LockIsolated(Presence.busy)
    let graph = heartbeatGraph(presence: .busy)
    let store = GraphStore(
      graph: graph,
      onDeliverMessage: { _, _, _ in
        delivered.withValue { $0 += 1 }
        return true
      },
      onReadPresence: { _, _ in
        PresenceReading(presence: presence.value, confidence: .reported)
      },
      onHeartbeatEnabled: { true })
    let nodeID = graph.nodes[0].id

    await store.deliverHeartbeat(nodeID)
    await store.deliverHeartbeat(nodeID)
    #expect(delivered.value == 0)

    presence.setValue(.idle)
    await store.deliverHeartbeat(nodeID)
    #expect(delivered.value == 1)
  }

  @Test
  func aStoppedLoopHearsNoFurtherBeats() async {
    let delivered = LockIsolated(0)
    let graph = heartbeatGraph()
    let store = GraphStore(
      graph: graph,
      onDeliverMessage: { _, _, _ in
        delivered.withValue { $0 += 1 }
        return true
      },
      onHeartbeatEnabled: { true })
    let nodeID = graph.nodes[0].id

    await store.handle(.stopNode(nodeID))
    await store.deliverHeartbeat(nodeID)

    // The stop request itself was one delivery; the beat after must add nothing.
    #expect(delivered.value == 1)
  }

  @Test
  func creatingAHeartbeatLoopNeedsTheExperimentOn() async {
    let draft = NodeDraft(
      title: "Watcher", loopType: .timeBased,
      triggerPrompt: "check reports", heartbeatIntervalSeconds: 300)

    let gated = GraphStore(onHeartbeatEnabled: { false })
    await gated.handle(.createNode(draft))
    #expect(await gated.graph.nodes.isEmpty)

    let open = GraphStore(onHeartbeatEnabled: { true })
    await open.handle(.createNode(draft))
    #expect(await open.graph.nodes.count == 1)
  }

  @Test
  func theHeartbeatPromptOwnsTheCadenceAndSaysSo() throws {
    let node = LoopNode(
      title: "Watcher", loopType: .timeBased,
      triggerPrompt: "check for new crash reports",
      heartbeatIntervalSeconds: 300)
    let prompt = try #require(node.sessionPrompt)
    #expect(prompt.contains("heartbeat"))
    #expect(prompt.contains("check for new crash reports"))
    #expect(prompt.contains("Do not schedule your own /loop"))

    // Without a heartbeat the prompt is exactly what it always was: the trigger
    // prompt, cadence inside it, no mention of any of this.
    let ordinary = LoopNode(
      title: "Watcher", loopType: .timeBased, triggerPrompt: "/loop 1h check reports")
    #expect(ordinary.sessionPrompt == "/loop 1h check reports")
  }

  @Test
  func codexAndOpenCodeUseDaemonCadenceWhenTheToggleIsOff() async {
    for backend in [CLISessionBackendKind.codex, .openCode] {
      let node = LoopNode(
        title: "Watcher", loopType: .timeBased,
        triggerPrompt: "/loop 30m check reports", backend: backend, state: .running)
      let delivered = LockIsolated(0)
      let graph = LoopGraph(
        project: ProjectRef(path: "/tmp/heartbeat", name: "heartbeat"), nodes: [node])
      let store = GraphStore(
        graph: graph,
        onDeliverMessage: { _, _, _ in
          delivered.withValue { $0 += 1 }
          return true
        },
        onHeartbeatEnabled: { false })

      #expect(node.effectiveHeartbeatInterval == 1800)
      #expect(node.sessionPrompt?.contains("Run one pass") == true)
      await store.deliverHeartbeat(node.id)
      #expect(delivered.value == 1)
    }
  }

  @Test
  func explicitCodexAndOpenCodeHeartbeatsIgnoreTheToggle() async {
    for backend in [CLISessionBackendKind.codex, .openCode] {
      let draft = NodeDraft(
        title: "Watcher", loopType: .timeBased,
        triggerPrompt: "check reports", heartbeatIntervalSeconds: 300, backend: backend)
      let delivered = LockIsolated(0)
      let store = GraphStore(
        onDeliverMessage: { _, _, _ in
          delivered.withValue { $0 += 1 }
          return true
        },
        onHeartbeatEnabled: { false })

      await store.handle(.createNode(draft))
      #expect(await store.graph.nodes.count == 1)
      if let node = await store.graph.nodes.first {
        await store.deliverHeartbeat(node.id)
      }
      #expect(delivered.value == 1)
    }
  }

  @Test
  func settingAnIntervalNeedsTheExperimentButClearingNeverDoes() async {
    // Turning the toggle off must not strand a loop with a cadence nobody can remove.
    let graph = heartbeatGraph()
    let store = GraphStore(graph: graph, onHeartbeatEnabled: { false })
    let nodeID = graph.nodes[0].id

    await store.handle(.updateNode(nodeID, update: NodeUpdate(heartbeatIntervalSeconds: 60)))
    #expect(await store.graph.nodes[0].heartbeatIntervalSeconds == 300)

    await store.handle(.updateNode(nodeID, update: NodeUpdate(heartbeatIntervalSeconds: 0)))
    #expect(await store.graph.nodes[0].heartbeatIntervalSeconds == nil)
  }

  @Test
  func theCLIParsesHeartbeatOnCreateAndUpdate() throws {
    let create = try GraphcodeCommand.parse([
      "node", "create", "/tmp/p", "--title", "W", "--type", "time",
      "--prompt", "check reports", "--heartbeat", "300",
    ])
    guard case .createNode(_, let draft, _) = create else {
      Issue.record("expected createNode, got \(create)")
      return
    }
    #expect(draft.heartbeatIntervalSeconds == 300)

    let update = try GraphcodeCommand.parse([
      "node", "update", "/tmp/p", UUID().uuidString, "--heartbeat", "0",
    ])
    guard case .updateNode(_, _, let nodeUpdate) = update else {
      Issue.record("expected updateNode, got \(update)")
      return
    }
    #expect(nodeUpdate.heartbeatIntervalSeconds == 0)

    #expect(throws: GraphcodeCommand.ParseError.self) {
      try GraphcodeCommand.parse([
        "node", "create", "/tmp/p", "--title", "W", "--type", "time",
        "--prompt", "check", "--heartbeat", "-5",
      ])
    }
    #expect(throws: GraphcodeCommand.ParseError.self) {
      try GraphcodeCommand.parse([
        "node", "create", "/tmp/p", "--title", "W", "--type", "time",
        "--prompt", "check", "--heartbeat", "inf",
      ])
    }
  }

  @Test
  func oldGraphsAndSettingsFilesDecodeToTheExperimentOff() throws {
    let settings = try JSONDecoder().decode(
      GraphcodeSettings.self, from: Data("{}".utf8))
    #expect(settings.daemonHeartbeatEnabled == false)

    let nodeJSON = """
      {"id":"00000000-0000-0000-0000-000000000001","title":"W",\
      "triggerPrompt":"/loop 1h check"}
      """
    let node = try JSONDecoder().decode(LoopNode.self, from: Data(nodeJSON.utf8))
    #expect(node.heartbeatIntervalSeconds == nil)
  }
}
