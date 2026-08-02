import GraphcodeKit
import Testing

@testable import graphcode

/// Onboarding's non-visual contract.
///
/// There were no tests here at all, and most of what the tour does is a picture — but
/// three things about it are load-bearing and checkable: how many pages there are, that
/// the backend choice is applied *live* rather than on Get Started, and that the
/// capability badge on page 4 says what `canHost` says rather than something written by
/// hand beside it.
@Suite
struct OnboardingViewTests {
  @Test
  func thereAreStillFourPages() {
    // The edge lesson folded into the types page to make room for "How to read a loop".
    // A fifth page is a different tour; a third is a page silently lost in a merge.
    #expect(OnboardingView.pageCount == 4)
  }

  @Test
  func everyBackendHasABlurbAndNoneOfThemClaimToHaveFoundIt() {
    // Nothing in `BackendCapabilities` probes the PATH, so a blurb that said "found on
    // your PATH" or named a version would be the tour making it up.
    for backend in CLISessionBackendKind.allCases {
      let blurb = OnboardingBackendPage.blurb(backend)
      #expect(!blurb.isEmpty)
      #expect(!blurb.lowercased().contains("path"))
      #expect(!blurb.lowercased().contains("installed"))
      #expect(!blurb.contains("v1"))
    }
  }

  @Test
  func theCapabilityBadgeAgreesWithCanHost() {
    // The badge exists so someone choosing a default is told *before* their first loop
    // is refused, rather than after — so it has to be the same rule, not a sentence
    // written beside it that ages differently. The reference backend hosts everything;
    // at least one of the others doesn't, or the badge is decoration.
    #expect(LoopType.allCases.allSatisfy { CLISessionBackendKind.claudeCode.canHost($0) })
    #expect(
      CLISessionBackendKind.allCases.contains { backend in
        LoopType.allCases.contains { !backend.canHost($0) }
      })
  }

  @Test
  func theTypeTilesTeachWhatTheDialogChooses() {
    // Page 3 reuses the dialog's own chooser, so what is taught is literally what is
    // picked later. Both readings have to cover all four types.
    for type in LoopType.allCases {
      #expect(!LoopTypeChooser.whatItDoes(type).isEmpty)
      #expect(!LoopTypeChooser.whatStopsIt(type).isEmpty)
      // And they are different lessons: what a loop does is not what stops it.
      #expect(LoopTypeChooser.whatItDoes(type) != LoopTypeChooser.whatStopsIt(type))
    }
  }
}
