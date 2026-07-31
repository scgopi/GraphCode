import Foundation
import GraphcodeKit
import Testing

@testable import graphcode

/// A loop that fans out must not hide its children behind an unexpanded chevron: the
/// parents of every *newly created* node get disclosed, and nothing else does — a
/// relaunch showing last month's graph keeps whatever the human had collapsed.
@Suite
struct SidebarAutoExpandTests {
  private func graph(nodes: [LoopNode], edges: [LoopEdge]) -> LoopGraph {
    LoopGraph(
      project: ProjectRef(path: "/tmp/p", name: "p"),
      nodes: .init(uniqueElements: nodes),
      edges: .init(uniqueElements: edges))
  }

  @Test
  func aNewChildDisclosesItsWholeAncestorChain() {
    let root = LoopNode(title: "root")
    let mid = LoopNode(title: "mid")
    let leaf = LoopNode(title: "leaf")
    let g = graph(
      nodes: [root, mid, leaf],
      edges: [
        LoopEdge(from: root.id, to: mid.id, fireCount: 1),
        LoopEdge(from: mid.id, to: leaf.id, fireCount: 1),
      ])

    // The grandchild is the new arrival: both levels above it must open, or it's
    // exactly as hidden as before.
    let parents = AppSidebarView.parentsToExpand(for: [leaf.id], in: [g])
    #expect(parents == [root.id, mid.id])
  }

  @Test
  func aNewRootDisclosesNothing() {
    let solo = LoopNode(title: "solo")
    let g = graph(nodes: [solo], edges: [])
    #expect(AppSidebarView.parentsToExpand(for: [solo.id], in: [g]).isEmpty)
  }

  @Test
  func anEdgeCycleDoesNotHangTheWalk() {
    let a = LoopNode(title: "a")
    let b = LoopNode(title: "b")
    let g = graph(
      nodes: [a, b],
      edges: [
        LoopEdge(from: a.id, to: b.id, fireCount: 1),
        LoopEdge(from: b.id, to: a.id, cycleGuard: CycleGuard(maxIterations: 3)),
      ])

    let parents = AppSidebarView.parentsToExpand(for: [b.id], in: [g])
    #expect(parents.contains(a.id))
  }
}
