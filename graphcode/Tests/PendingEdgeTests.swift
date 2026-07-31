import Foundation
import GraphcodeKit
import Testing

@testable import graphcode

/// The edge editor's draft → the `EdgeSpec` actually sent. What matters is the folding:
/// the picker/text/toggle state has to become exactly the guard the daemon will enforce,
/// because a control that looks set but doesn't travel is a silent no-op in shipping UI.
@Suite
struct PendingEdgeTests {
  private func draft() -> ProjectFeature.PendingEdge {
    ProjectFeature.PendingEdge(from: UUID(), to: UUID())
  }

  @Test
  func aNonLoopingEdgeCarriesNoGuard() {
    #expect(draft().resolvedSpec.cycleGuard == nil)
  }

  @Test
  func thePlateauBoundTravelsOnlyWhenSwitchedOn() {
    var pending = draft()
    pending.loops = true
    pending.maxIterations = 5

    #expect(pending.resolvedSpec.cycleGuard?.stopAfterPassesWithoutImprovement == nil)

    pending.stopsOnPlateau = true
    pending.plateauPasses = 3
    let guardSpec = pending.resolvedSpec.cycleGuard
    #expect(guardSpec?.stopAfterPassesWithoutImprovement == 3)
    // The iteration cap still rides along — a metric that never exists must not mean
    // an unbounded loop.
    #expect(guardSpec?.maxIterations == 5)
    #expect(guardSpec?.isBounded == true)
  }

  @Test
  func theUntilCommandAndPlateauCoexist() {
    var pending = draft()
    pending.loops = true
    pending.untilCommand = "make test"
    pending.stopsOnPlateau = true

    let guardSpec = pending.resolvedSpec.cycleGuard
    #expect(guardSpec?.until == "make test")
    #expect(guardSpec?.stopAfterPassesWithoutImprovement == 2)
  }
}
