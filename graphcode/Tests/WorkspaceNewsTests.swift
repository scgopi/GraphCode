import Foundation
import Testing

@testable import graphcode

/// Who gets told that workspaces exist.
///
/// The trap this pins: nothing before 0.1.46 recorded a version, so the *absence* of one
/// means an old install, not a new one. Reading it the other way would show the news to
/// every fresh install — on top of the tour page that already teaches it — and show it to
/// nobody who actually needed it.
@Suite
struct WorkspaceNewsTests {
  private func announces(
    current: String = "0.1.46", lastRun: String?, hasSeenOnboarding: Bool
  ) -> Bool {
    WorkspaceNews.shouldAnnounce(
      currentVersion: current, lastRunVersion: lastRun, hasSeenOnboarding: hasSeenOnboarding)
  }

  @Test
  func someoneUpgradingFromBeforeWorkspacesIsTold() {
    #expect(announces(lastRun: "0.1.45", hasSeenOnboarding: true))
    #expect(announces(lastRun: "0.1.30-beta2", hasSeenOnboarding: true))
    // The version key did not exist before this release, so an install with no record of
    // its last run is an old one — which is exactly the audience.
    #expect(announces(lastRun: nil, hasSeenOnboarding: true))
    // Unparsable is treated the same way rather than swallowed.
    #expect(announces(lastRun: "not-a-version", hasSeenOnboarding: true))
  }

  @Test
  func aFreshInstallIsNotToldTwice() {
    // It learns this from the tour's own page; the dialog as well would be the same
    // lesson twice in one sitting.
    #expect(!announces(lastRun: nil, hasSeenOnboarding: false))
    #expect(!announces(lastRun: "0.1.45", hasSeenOnboarding: false))
  }

  @Test
  func nobodyIsToldTwiceOnLaterLaunches() {
    // Once this release has run, its version is recorded — every later launch is quiet.
    #expect(!announces(lastRun: "0.1.46", hasSeenOnboarding: true))
    #expect(!announces(lastRun: "0.1.46-beta5", hasSeenOnboarding: true))
    #expect(!announces(current: "0.1.47", lastRun: "0.1.46", hasSeenOnboarding: true))
  }

  @Test
  func abetaOfTheIntroducingReleaseCounts() {
    // 0.1.46-beta1 sorts before 0.1.46 and is where workspaces actually shipped, so
    // someone coming from 0.1.45 to a beta must still be told.
    #expect(announces(current: "0.1.46-beta1", lastRun: "0.1.45", hasSeenOnboarding: true))
    // …and someone already on a beta of it must not be told again on the stable.
    #expect(!announces(current: "0.1.46", lastRun: "0.1.46-beta1", hasSeenOnboarding: true))
  }

  @Test
  func theVersionIsRecordedWhicheverWayItIsAnswered() {
    let defaults = UserDefaults(suiteName: "news-\(UUID().uuidString)")!
    defaults.set(true, forKey: WorkspaceNews.hasSeenOnboardingKey)
    defaults.set("0.1.45", forKey: WorkspaceNews.lastRunVersionKey)

    #expect(WorkspaceNews.announceIfNeeded(currentVersion: "0.1.46", defaults: defaults))
    #expect(defaults.string(forKey: WorkspaceNews.lastRunVersionKey) == "0.1.46")
    // Asked once per machine however it was answered — including by ignoring it.
    #expect(!WorkspaceNews.announceIfNeeded(currentVersion: "0.1.46", defaults: defaults))
  }
}
