import ComposableArchitecture
import Foundation
import GraphcodeKit
import Testing

/// `node send` to a loop whose session died unattended. Before issue #215's fix the
/// send either lied — a husked session answered every existence check, so "delivered"
/// typed into a dead PTY — or staged the message to a memory that a dead loop has no
/// way to wake and read. Now the failed delivery is the moment the store revives the
/// loop: the ensure is create-only and husk-aware, so it relaunches exactly the dead
/// case, and the retry lands the message.
@Suite
struct RespawnOnSendTests {
  private func graph(state: LoopState) -> LoopGraph {
    LoopGraph(
      project: ProjectRef(path: "/tmp/respawn", name: "respawn"),
      nodes: [
        LoopNode(
          title: "Worker", loopType: .goalBased,
          goal: GoalSpec(summary: "work"), state: state)
      ])
  }

  @Test
  func aFailedDeliveryToAnUnattendedLoopRespawnsAndRetries() async {
    let deliveries = LockIsolated(0)
    let ensured = LockIsolated(0)
    let remembered = LockIsolated<[String]>([])
    let graph = graph(state: .running)
    let store = GraphStore(
      graph: graph,
      onEnsureSession: { _, _ in ensured.withValue { $0 += 1 } },
      onDeliverMessage: { _, _, _ in
        // First attempt: the session is a husk — the gate refuses it. Second: relaunched.
        deliveries.withValue { $0 += 1 }
        return deliveries.value > 1
      },
      onAppendMemory: { _, entry in remembered.withValue { $0.append(entry) } })
    let nodeID = graph.nodes[0].id

    await store.handle(.messageNode(nodeID, text: "wake up", from: nil, followUp: nil))

    #expect(deliveries.value == 2)
    #expect(ensured.value == 1)
    #expect(remembered.value.isEmpty)
  }

  @Test
  func aDeliveryThatStillFailsAfterRespawnIsStaged() async {
    let deliveries = LockIsolated(0)
    let remembered = LockIsolated<[String]>([])
    let graph = graph(state: .running)
    let store = GraphStore(
      graph: graph,
      onEnsureSession: { _, _ in },
      onDeliverMessage: { _, _, _ in
        deliveries.withValue { $0 += 1 }
        return false
      },
      onAppendMemory: { _, entry in remembered.withValue { $0.append(entry) } })
    let nodeID = graph.nodes[0].id

    await store.handle(.messageNode(nodeID, text: "wake up", from: nil, followUp: nil))

    #expect(deliveries.value == 2)
    #expect(remembered.value.contains { $0.contains("while you were away") })
  }

  @Test
  func anAttendedLoopIsNeverRespawnedByAMessage() async {
    // A turn-based session is a human's: the human opening it is what starts it, and a
    // message arriving must not spawn work the graph says waits for a person.
    let deliveries = LockIsolated(0)
    let ensured = LockIsolated(0)
    var graph = graph(state: .running)
    graph.nodes[0].loopType = .turnBased
    let store = GraphStore(
      graph: graph,
      onEnsureSession: { _, _ in ensured.withValue { $0 += 1 } },
      onDeliverMessage: { _, _, _ in
        deliveries.withValue { $0 += 1 }
        return false
      },
      onAppendMemory: { _, _ in })
    let nodeID = graph.nodes[0].id

    await store.handle(.messageNode(nodeID, text: "wake up", from: nil, followUp: nil))

    #expect(deliveries.value == 1)
    #expect(ensured.value == 0)
  }

  @Test
  func aResolvedLoopIsNotRespawned() async {
    let ensured = LockIsolated(0)
    let graph = graph(state: .succeeded)
    let store = GraphStore(
      graph: graph,
      onEnsureSession: { _, _ in ensured.withValue { $0 += 1 } },
      onDeliverMessage: { _, _, _ in false },
      onAppendMemory: { _, _ in })
    let nodeID = graph.nodes[0].id

    await store.handle(.messageNode(nodeID, text: "wake up", from: nil, followUp: nil))

    #expect(ensured.value == 0)
  }
}
