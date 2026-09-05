import Foundation
import Testing

@testable import graphcode

/// The board's scroll box is capped by a share of the rail, so a rigid box can never be
/// what pushes the foot of the rail off a short window.
@Suite
struct MailroomRailShareTests {
  @Test
  func theBoardTakesAShareOfTheRailNotAFixedHeight() {
    // A 900pt rail: half is 450, well under the 820 ceiling and well over the floor.
    #expect(LoopWorkspaceRail.mailroomHeightCap(railHeight: 900) == 450)
    // A tall rail: the share would exceed the ceiling, so the ceiling wins — fourteen
    // posts is enough on any window.
    #expect(LoopWorkspaceRail.mailroomHeightCap(railHeight: 2000) == 820)
    #expect(MailroomSection.maxScrollHeight == 820)
  }

  /// A very short rail still shows a couple of posts rather than a sliver; below the
  /// floor the rail has bigger problems than this section.
  @Test
  func aShortRailStillShowsSomething() {
    #expect(LoopWorkspaceRail.mailroomHeightCap(railHeight: 300) == 200)
    #expect(LoopWorkspaceRail.mailroomHeightCap(railHeight: 0) == 200)
  }

  /// The share leaves room for everything rigid above it: THIS LOOP (118) plus the
  /// summary's floor (120) plus chrome, on a rail that fits one 1280×800 window.
  @Test
  func theShareLeavesRoomForTheRigidSections() {
    let rail: CGFloat = 700
    let board = LoopWorkspaceRail.mailroomHeightCap(railHeight: rail)
    let rigidAbove: CGFloat = 118 + 120 + 24 + 24 + 12 * 2
    #expect(board + rigidAbove < rail)
  }
}
