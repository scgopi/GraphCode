import Foundation
import GraphcodeKit

// Build a small implement -> review -> ship graph with a review failure that
// repasses back into implement under a bounded cycle guard.
var implement = LoopNode(title: "Implement", loopType: .goalBased)
implement.backend = .copilotCLI
implement.modelTier = .capable
implement.firstInstruction = "Implement the claimed issue in the worktree."
implement.goal = GoalSpec(
  summary: "The change compiles and its tests pass.",
  predicate: "swift build")

var review = LoopNode(title: "Review", loopType: .turnBased)
review.backend = .claudeCode
review.pausesBeforeWritesOnly = true
review.firstInstruction = "Adversarially review the diff. Return a verdict only."

var ship = LoopNode(title: "Open PR", loopType: .goalBased)
ship.backend = .copilotCLI
ship.goal = GoalSpec(summary: "A pull request is open for the branch.")

var graph = LoopGraph(scope: .project(ProjectRef(path: "/tmp/demo", name: "demo")))
graph.nodes = [implement, review, ship]

var toReview = LoopEdge(from: implement.id, to: review.id, kind: .handoff)
toReview.condition = .always

var pass = LoopEdge(from: review.id, to: ship.id, kind: .handoff)
pass.condition = .onSuccess

var repass = LoopEdge(from: review.id, to: implement.id, kind: .handoff)
repass.condition = .onFailure
repass.cycleGuard = CycleGuard(maxIterations: 3)

graph.edges = [toReview, pass, repass]

let outputRoot = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "./out"
do {
  let bundle = try GoobersExport.export(
    graph: graph,
    workflowName: "implementation",
    gaggleName: "demo",
    project: .init(owner: "Agent-Clubhouse", name: "Goobers"))
  for (path, contents) in bundle.files.sorted(by: { $0.key < $1.key }) {
    let url = URL(fileURLWithPath: outputRoot).appendingPathComponent(path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try contents.write(to: url, atomically: true, encoding: .utf8)
    print("wrote \(path)")
  }
} catch let error as GoobersExport.ExportError {
  print("EXPORT REFUSED:\n" + error.localizedDescription)
  exit(1)
}

// --- Negative cases: constructs that must be refused, not silently flattened.
func expectRefusal(_ label: String, _ build: () -> LoopGraph) {
  do {
    _ = try GoobersExport.export(
      graph: build(), workflowName: "wf", gaggleName: "demo",
      project: .init(owner: "o", name: "n"))
    print("FAIL \(label): expected refusal, got a bundle")
  } catch let error as GoobersExport.ExportError {
    print("OK   \(label): \(error.diagnostics.count) diagnostic(s)")
    for d in error.diagnostics {
      print("       - " + d.message.split(separator: "\n").joined(separator: " "))
    }
  } catch { print("FAIL \(label): \(error)") }
}

expectRefusal("unsupported backend (codex)") {
  var n = LoopNode(title: "Codex node", loopType: .goalBased)
  n.backend = .codex
  var g = LoopGraph(scope: .project(ProjectRef(path: "/tmp/d", name: "d")))
  g.nodes = [n]
  return g
}

expectRefusal("time-based node") {
  var n = LoopNode(title: "Timed node", loopType: .timeBased)
  n.backend = .copilotCLI
  var g = LoopGraph(scope: .project(ProjectRef(path: "/tmp/d", name: "d")))
  g.nodes = [n]
  return g
}

expectRefusal("message edge") {
  var a = LoopNode(title: "A", loopType: .goalBased)
  a.backend = .copilotCLI
  var b = LoopNode(title: "B", loopType: .goalBased)
  b.backend = .copilotCLI
  var g = LoopGraph(scope: .project(ProjectRef(path: "/tmp/d", name: "d")))
  g.nodes = [a, b]
  g.edges = [LoopEdge(from: a.id, to: b.id, kind: .message)]
  return g
}

expectRefusal("multiple entry points") {
  var a = LoopNode(title: "A", loopType: .goalBased)
  a.backend = .copilotCLI
  var b = LoopNode(title: "B", loopType: .goalBased)
  b.backend = .copilotCLI
  var c = LoopNode(title: "C", loopType: .goalBased)
  c.backend = .copilotCLI
  var d = LoopNode(title: "D", loopType: .goalBased)
  d.backend = .copilotCLI
  var g = LoopGraph(scope: .project(ProjectRef(path: "/tmp/d", name: "d")))
  g.nodes = [a, b, c, d]
  g.edges = [
    LoopEdge(from: a.id, to: b.id),
    LoopEdge(from: c.id, to: d.id),
  ]
  return g
}

expectRefusal("adaptive cycle guard") {
  var a = LoopNode(title: "A", loopType: .goalBased)
  a.backend = .copilotCLI
  var b = LoopNode(title: "B", loopType: .goalBased)
  b.backend = .copilotCLI
  var g = LoopGraph(scope: .project(ProjectRef(path: "/tmp/d", name: "d")))
  g.nodes = [a, b]
  g.edges = [
    LoopEdge(from: a.id, to: b.id),
    LoopEdge(
      from: b.id, to: a.id,
      cycleGuard: CycleGuard(maxIterations: 3, until: "test -f done")),
  ]
  return g
}

expectRefusal("unguarded cycle") {
  var a = LoopNode(title: "A", loopType: .goalBased)
  a.backend = .copilotCLI
  var b = LoopNode(title: "B", loopType: .goalBased)
  b.backend = .copilotCLI
  var g = LoopGraph(scope: .project(ProjectRef(path: "/tmp/d", name: "d")))
  g.nodes = [a, b]
  g.edges = [
    LoopEdge(from: a.id, to: b.id, kind: .handoff),
    LoopEdge(from: b.id, to: a.id, kind: .handoff),
  ]
  return g
}

expectRefusal("fan-out without join") {
  var a = LoopNode(title: "A", loopType: .goalBased)
  a.backend = .copilotCLI
  var b = LoopNode(title: "B", loopType: .goalBased)
  b.backend = .copilotCLI
  var c = LoopNode(title: "C", loopType: .goalBased)
  c.backend = .copilotCLI
  var g = LoopGraph(scope: .project(ProjectRef(path: "/tmp/d", name: "d")))
  g.nodes = [a, b, c]
  g.edges = [
    LoopEdge(from: a.id, to: b.id, kind: .handoff),
    LoopEdge(from: a.id, to: c.id, kind: .handoff),
  ]
  return g
}
