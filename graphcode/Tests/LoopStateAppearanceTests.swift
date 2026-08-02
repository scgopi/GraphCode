import GraphcodeKit
import SwiftUI
import Testing

@testable import graphcode

/// The state vocabulary (`LoopStateAppearance`).
///
/// The defect being fixed is that eight states were drawn with five hues and nothing
/// else, so `awaitingInput`/`blocked` and `idle`/`stopped` were literally the same
/// pixels. These tests are the regression guard for that: they assert the *separation*
/// rather than the individual values, so a future palette change is free but a palette
/// change that re-collapses a pair is not.
@Suite
struct LoopStateAppearanceTests {
  private let allStates = LoopState.allCases

  @Test
  func everyStateHasItsOwnWordAndIndicatorStyle() {
    for loopType in LoopType.allCases {
      let pairs = allStates.map { ($0.displayWord(for: loopType), $0.indicatorIsHollow) }
      let distinct = Set(pairs.map { "\($0.0)/\($0.1)" })

      #expect(distinct.count == allStates.count)
      #expect(pairs.allSatisfy { !$0.0.isEmpty })
    }
  }

  @Test
  func statesSharingAHueNeverShareAnIndicatorStyle() {
    // The actual guard. Take the colour away — greyscale, 40% zoom, a protanope — and
    // every pair still separates, because the pairs that share a hue differ in shape.
    for (index, state) in allStates.enumerated() {
      for other in allStates.dropFirst(index + 1) {
        let sameNewHue = state.indicatorTint == other.indicatorTint
        let sameLegacyHue = state.presenceColor == other.presenceColor
        guard sameNewHue || sameLegacyHue else { continue }

        #expect(
          state.indicatorIsHollow != other.indicatorIsHollow,
          "\(state) and \(other) share a hue and an indicator style")
      }
    }
  }

  @Test
  func theTwoPairsThatUsedToCollideAreTheOnesCarryingTheShape() {
    // Naming them, so the test above can't pass vacuously if a palette change makes
    // every hue unique and the shape channel quietly stops being exercised.
    #expect(LoopState.awaitingInput.indicatorTint == LoopState.blocked.indicatorTint)
    #expect(LoopState.idle.indicatorTint == LoopState.stopped.indicatorTint)
    #expect(LoopState.blocked.indicatorIsHollow)
    #expect(LoopState.stopped.indicatorIsHollow)
    #expect(!LoopState.awaitingInput.indicatorIsHollow)
    #expect(!LoopState.idle.indicatorIsHollow)
    #expect(allStates.filter(\.indicatorIsHollow).count == 2)
  }

  @Test
  func idleReadsScheduledOnlyWhenSomethingIsActuallyScheduled() {
    // A time-based loop at rest will run again on its own. Anything else at rest is
    // waiting on a person to start it, and saying SCHEDULED there would promise a tick
    // that is never coming.
    #expect(LoopState.idle.displayWord(for: .timeBased) == "SCHEDULED")
    for loopType in LoopType.allCases where loopType != .timeBased {
      #expect(LoopState.idle.displayWord(for: loopType) == "IDLE")
    }
  }

  @Test
  func onlyIdleReadsDifferentlyPerKind() {
    for state in allStates where state != .idle {
      let words = Set(LoopType.allCases.map { state.displayWord(for: $0) })
      #expect(words.count == 1, "\(state) says different things about different kinds")
    }
  }

  @Test
  func theTwoOrangesAreStillTwoDifferentThings() {
    // Orange used to mean "asking", "stuck", and "look here" at once. It can still mean
    // the first two, but never at the same weight.
    #expect(LoopState.awaitingInput.pillFill != LoopState.blocked.pillFill)
    #expect(LoopState.blocked.pillStroke != nil)
    #expect(LoopState.awaitingInput.pillStroke == nil)
    #expect(LoopState.awaitingInput.displayWord(for: .goalBased) == "NEEDS YOU")
    #expect(LoopState.blocked.displayWord(for: .goalBased) == "BLOCKED")
  }

  @Test
  func onlyTheStatesStalledOnAPersonAskForOne() {
    #expect(allStates.filter(\.wantsHuman) == [.awaitingInput, .blocked])
  }

  // There is no test that the running dot doesn't pulse, and that is on purpose: SwiftUI
  // offers no way to assert the absence of an animation that isn't a reflection trick
  // more fragile than the thing it guards. The reason it was removed is on
  // `StateIndicator`, where anyone tempted to put it back will read it — a `repeatForever`
  // animation never settles, and this indicator is on screen in every pane.

  @Test
  func everyKindHasAOneWordNameAndNoneOfThemIsARawValue() {
    for loopType in LoopType.allCases {
      #expect(!loopType.displayName.contains(loopType.rawValue))
      #expect(!loopType.displayName.isEmpty)
    }
    #expect(Set(LoopType.allCases.map(\.displayName)).count == LoopType.allCases.count)
  }
}
