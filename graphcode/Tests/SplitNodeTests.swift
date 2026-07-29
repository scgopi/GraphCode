import Foundation
import GraphcodeKit
import Testing

/// The shape a tab's panes take, on its own — `LoopWorkspaceFeature` decides *which* pane
/// to split and where the keyboard goes afterward, and those are tested next door in
/// `LoopWorkspaceFeatureTests` and `SplitPaneFocusTests`.
///
/// Worth pinning separately because this is the type that replaced "one pane and maybe one
/// more", and the rules it enforces (siblings on a shared axis, containers collapsing when
/// they run out of children) are what stop repeated ⌘D producing a layout nobody asked for.
@Suite
struct SplitNodeTests {
  private func surface() -> SurfaceRef { SurfaceRef(id: UUID(), launchesClaudeCode: false) }

  @Test
  func splittingALeafGivesTwoPanesOnTheChosenAxis() {
    let original = surface()
    let addition = surface()

    let root = SplitNode.leaf(original).splitting(
      original.id, with: addition, direction: .vertical)

    guard case .split(let direction, let children) = root else {
      return #expect(Bool(false), "splitting a leaf should produce a split")
    }
    #expect(direction == .vertical)
    #expect(children.map(\.id) == [original.id, addition.id])
  }

  @Test
  func splittingTheSameAxisAgainAddsASiblingRatherThanNesting() {
    let first = surface()
    var root = SplitNode.leaf(first)
    var added: [UUID] = []

    // Split the pane that was just added each time, the way ⌘D does.
    var target = first.id
    for _ in 0..<3 {
      let addition = surface()
      root = root.splitting(target, with: addition, direction: .horizontal)
      added.append(addition.id)
      target = addition.id
    }

    guard case .split(let direction, let children) = root else {
      return #expect(Bool(false), "three splits should produce a split")
    }
    #expect(direction == .horizontal)
    // Flat, so the four panes divide the tab evenly instead of 1/2, 1/4, 1/8, 1/8.
    #expect(children.count == 4)
    #expect(children.allSatisfy { !$0.isSplit })
    #expect(root.surfaces.map(\.id) == [first.id] + added)
  }

  @Test
  func splittingTheOtherAxisNestsInsideTheTargetPane() {
    let first = surface()
    let second = surface()
    let third = surface()

    var root = SplitNode.leaf(first).splitting(first.id, with: second, direction: .horizontal)
    root = root.splitting(second.id, with: third, direction: .vertical)

    guard case .split(.horizontal, let children) = root, children.count == 2 else {
      return #expect(Bool(false), "the outer split should still be a row of two")
    }
    guard case .split(.vertical, let inner) = children[1] else {
      return #expect(Bool(false), "the second pane should have become a column")
    }
    #expect(inner.map(\.id) == [second.id, third.id])
    #expect(root.surfaces.map(\.id) == [first.id, second.id, third.id])
  }

  @Test
  func splittingAPaneThisTreeDoesNotHaveChangesNothing() {
    let only = surface()
    let root = SplitNode.leaf(only)

    #expect(root.splitting(UUID(), with: surface(), direction: .horizontal) == root)
  }

  @Test
  func removingThePenultimatePaneCollapsesItsContainer() {
    let first = surface()
    let second = surface()
    let third = surface()

    var root = SplitNode.leaf(first).splitting(first.id, with: second, direction: .horizontal)
    root = root.splitting(second.id, with: third, direction: .vertical)

    // The column of two loses one, so it stops being a column: the survivor takes the
    // whole half the column occupied.
    let after = root.removing(third.id)
    #expect(after == .split(direction: .horizontal, children: [.leaf(first), .leaf(second)]))
  }

  @Test
  func removingTheLastPaneLeavesNothing() {
    let only = surface()
    #expect(SplitNode.leaf(only).removing(only.id) == nil)
  }

  @Test
  func aTreeSurvivesARoundTripThroughDisk() throws {
    let first = surface()
    let second = surface()
    let third = surface()
    var root = SplitNode.leaf(first).splitting(first.id, with: second, direction: .horizontal)
    root = root.splitting(second.id, with: third, direction: .vertical)

    let data = try JSONEncoder().encode(root)
    #expect(try JSONDecoder().decode(SplitNode.self, from: data) == root)
  }

  /// The layout on disk for anyone who split a tab before it could hold more than two
  /// panes. It has to come back as the same two panes on the same axis — a tab that failed
  /// to decode is a tab whose terminals are still running with nothing pointing at them.
  @Test
  func aTwoPaneLayoutSavedByAnEarlierBuildDecodesIntoATree() throws {
    let tabID = UUID()
    let primaryID = UUID()
    let secondaryID = UUID()
    let json = """
      {"tabs":[{"id":"\(tabID.uuidString)",
      "primary":{"id":"\(primaryID.uuidString)","launchesClaudeCode":true},
      "secondary":{"id":"\(secondaryID.uuidString)","launchesClaudeCode":false},
      "splitDirection":{"vertical":{}},
      "focusedSurfaceID":"\(secondaryID.uuidString)"}],
      "selectedTabID":"\(tabID.uuidString)"}
      """
    let data = try #require(json.data(using: .utf8))

    let layout = try JSONDecoder().decode(TerminalLayout.self, from: data)

    let tab = try #require(layout.tabs[id: tabID])
    #expect(tab.surfaces.map(\.id) == [primaryID, secondaryID])
    #expect(tab.focusedSurface.id == secondaryID)
    #expect(
      tab.root
        == .split(
          direction: .vertical,
          children: [
            .leaf(SurfaceRef(id: primaryID, launchesClaudeCode: true)),
            .leaf(SurfaceRef(id: secondaryID, launchesClaudeCode: false)),
          ]))
  }
}
