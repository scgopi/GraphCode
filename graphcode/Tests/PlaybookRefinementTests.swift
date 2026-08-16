import ComposableArchitecture
import Foundation
import Testing

@testable import GraphcodeKit

/// The continual harness: a node's playbook — its refinable supplemental prompt —
/// rewritten whole by `node refine`, snapshotted for rollback, and carried into every
/// wake digest ahead of the history. The base briefing and the stop condition stay out
/// of its reach by construction: they are different files with different owners.
@Suite
struct PlaybookRefinementTests {
  private let projectPath = "/tmp/refine-tests"
  private let nodeID = UUID()

  private func temporaryBase() throws -> URL {
    let base = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("graphcode-playbook-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
  }

  @Test
  func refineWritesAndTheWakeDigestCarriesItAheadOfHistory() throws {
    let base = try temporaryBase()
    defer { try? FileManager.default.removeItem(at: base) }

    NodeMemory.append("resolved: pass one", projectPath: projectPath, nodeID: nodeID, baseURL: base)
    #expect(
      NodeMemory.refinePlaybook(
        "Always run make check before claiming done.",
        projectPath: projectPath, nodeID: nodeID, baseURL: base))

    let digestURL = try #require(
      NodeMemory.writeWakeDigest(projectPath: projectPath, nodeID: nodeID, baseURL: base))
    let digest = try String(contentsOf: digestURL, encoding: .utf8)
    let playbookIndex = try #require(digest.range(of: "Always run make check"))
    let historyIndex = try #require(digest.range(of: "resolved: pass one"))
    #expect(playbookIndex.lowerBound < historyIndex.lowerBound)
    #expect(digest.contains("graphcode node refine"))
  }

  @Test
  func aPlaybookAloneStillEarnsAWakeDigest() throws {
    // Refinement is exactly the knowledge a fresh session must start from, log or no.
    let base = try temporaryBase()
    defer { try? FileManager.default.removeItem(at: base) }

    #expect(
      NodeMemory.refinePlaybook(
        "Prefer small diffs.", projectPath: projectPath, nodeID: nodeID, baseURL: base))
    #expect(
      NodeMemory.writeWakeDigest(projectPath: projectPath, nodeID: nodeID, baseURL: base) != nil)
    // And a node with neither still gets none — a first launch must not be told to go
    // read an empty file.
    #expect(
      NodeMemory.writeWakeDigest(projectPath: projectPath, nodeID: UUID(), baseURL: base) == nil)
  }

  @Test
  func rollbackRestoresTheVersionRefineReplaced() throws {
    let base = try temporaryBase()
    defer { try? FileManager.default.removeItem(at: base) }

    #expect(
      NodeMemory.refinePlaybook("v1", projectPath: projectPath, nodeID: nodeID, baseURL: base))
    #expect(
      NodeMemory.refinePlaybook("v2", projectPath: projectPath, nodeID: nodeID, baseURL: base))
    #expect(
      NodeMemory.playbook(forProjectPath: projectPath, nodeID: nodeID, baseURL: base) == "v2")

    #expect(NodeMemory.rollbackPlaybook(projectPath: projectPath, nodeID: nodeID, baseURL: base))
    #expect(
      NodeMemory.playbook(forProjectPath: projectPath, nodeID: nodeID, baseURL: base) == "v1")
    // One snapshot, one undo: a second rollback has nothing left to restore.
    #expect(!NodeMemory.rollbackPlaybook(projectPath: projectPath, nodeID: nodeID, baseURL: base))
  }

  @Test
  func snapshotsAreBoundedAndOrderedAcrossManyRefinements() throws {
    let base = try temporaryBase()
    defer { try? FileManager.default.removeItem(at: base) }

    for version in 1...8 {
      #expect(
        NodeMemory.refinePlaybook(
          "v\(version)", projectPath: projectPath, nodeID: nodeID, baseURL: base))
    }
    let directory = NodeMemory.directory(
      forProjectPath: projectPath, nodeID: nodeID, baseURL: base)
    let snapshots = try FileManager.default.contentsOfDirectory(atPath: directory.path)
      .filter { $0.hasPrefix("PLAYBOOK.") && $0 != "PLAYBOOK.md" }
    #expect(snapshots.count == NodeMemory.playbookSnapshotLimit)

    // Undo steps back through the retained tail, newest first.
    #expect(NodeMemory.rollbackPlaybook(projectPath: projectPath, nodeID: nodeID, baseURL: base))
    #expect(
      NodeMemory.playbook(forProjectPath: projectPath, nodeID: nodeID, baseURL: base) == "v7")
  }

  @Test
  func emptyAndOversizedPlaybooksAreRefusedWholesale() throws {
    let base = try temporaryBase()
    defer { try? FileManager.default.removeItem(at: base) }

    #expect(
      !NodeMemory.refinePlaybook("   ", projectPath: projectPath, nodeID: nodeID, baseURL: base))
    let oversized = String(repeating: "x", count: NodeMemory.maxPlaybookBytes + 1)
    #expect(
      !NodeMemory.refinePlaybook(
        oversized, projectPath: projectPath, nodeID: nodeID, baseURL: base))
    // Refused means untouched — not truncated, not created.
    #expect(NodeMemory.playbook(forProjectPath: projectPath, nodeID: nodeID, baseURL: base) == nil)
  }

  @Test
  func theStoreRecordsARefinementAndSaysWhoMadeIt() async {
    let refined = LockIsolated<[(UUID, String)]>([])
    let remembered = LockIsolated<[String]>([])
    let graph = LoopGraph(
      project: ProjectRef(path: "/tmp/p", name: "p"),
      nodes: [
        LoopNode(title: "Worker", loopType: .goalBased, goal: GoalSpec(summary: "work")),
        LoopNode(title: "Coach", loopType: .goalBased, goal: GoalSpec(summary: "advise")),
      ])
    let store = GraphStore(
      graph: graph,
      onAppendMemory: { _, entry in remembered.withValue { $0.append(entry) } },
      onRefinePlaybook: { nodeID, text in
        refined.withValue { $0.append((nodeID, text)) }
        return true
      })
    let (workerID, coachID) = (graph.nodes[0].id, graph.nodes[1].id)

    // Self-refinement is the feature, and needs no attribution.
    await store.handle(.refineNode(workerID, text: "Test first.", from: workerID))
    #expect(refined.value.count == 1)
    #expect(remembered.value.contains { $0.contains("playbook refined (") })

    // A peer's refinement names its author, the way a memo from a peer does.
    await store.handle(.refineNode(workerID, text: "Test first, then lint.", from: coachID))
    #expect(remembered.value.contains { $0.contains("playbook refined by Coach") })
  }

  @Test
  func theStoreRefusesEmptyAndOversizedBeforeTheFileLayerSeesThem() async {
    // Refused at the store means the hook is never called and nothing lands in the
    // memory log — the loop hears the refusal (announceError) instead of silently
    // working from a playbook it believes it replaced.
    let refineCalls = LockIsolated(0)
    let remembered = LockIsolated<[String]>([])
    let graph = LoopGraph(
      project: ProjectRef(path: "/tmp/p", name: "p"),
      nodes: [LoopNode(title: "Worker", loopType: .goalBased, goal: GoalSpec(summary: "work"))])
    let store = GraphStore(
      graph: graph,
      onAppendMemory: { _, entry in remembered.withValue { $0.append(entry) } },
      onRefinePlaybook: { _, _ in
        refineCalls.withValue { $0 += 1 }
        return true
      })

    await store.handle(.refineNode(graph.nodes[0].id, text: "   ", from: nil))
    let oversized = String(repeating: "x", count: NodeMemory.maxPlaybookBytes + 1)
    await store.handle(.refineNode(graph.nodes[0].id, text: oversized, from: nil))
    await store.handle(.rollbackRefinement(UUID(), from: nil))

    #expect(refineCalls.value == 0)
    #expect(!remembered.value.contains { $0.contains("playbook") })
  }

  @Test
  func theCLIParsesAllThreeSpellings() throws {
    let id = UUID()
    let words = try GraphcodeCommand.parse([
      "node", "refine", "/tmp/p", id.uuidString, "Test", "first.",
    ])
    guard case .refineNode(_, _, let text) = words else {
      Issue.record("expected refineNode, got \(words)")
      return
    }
    #expect(text == "Test first.")

    let rollback = try GraphcodeCommand.parse([
      "node", "refine", "/tmp/p", id.uuidString, "--rollback",
    ])
    guard case .rollbackRefinement = rollback else {
      Issue.record("expected rollbackRefinement, got \(rollback)")
      return
    }

    let file = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("playbook-\(UUID().uuidString).md")
    try "Line one\nLine two\n".write(to: file, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: file) }
    let fromFile = try GraphcodeCommand.parse([
      "node", "refine", "/tmp/p", id.uuidString, "--file", file.path,
    ])
    guard case .refineNode(_, _, let fileText) = fromFile else {
      Issue.record("expected refineNode, got \(fromFile)")
      return
    }
    #expect(fileText.contains("Line one\nLine two"))
  }
}
