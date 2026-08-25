import ComposableArchitecture
import Foundation
import GraphcodeKit
import Testing

@testable import graphcode

/// The bundle in /Applications can be replaced while a window is open — `brew upgrade`,
/// a DMG dragged over it, an install whose relaunch was declined. The app then keeps
/// running code that is no longer on disk, and its `graphcoded` stays the old one: the
/// bootstrap that installs the helpers and reloads the daemon runs at launch, so nothing
/// applies until a relaunch. This is the window noticing and saying so.
@Suite
@MainActor
struct SwappedBundleTests {
  @Test
  func aSwappedBundleRaisesTheRelaunchPrompt() async {
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.updateClient.swappedBundleStamp = { "graphcoded:1:2" }
    }
    await store.send(.bundleSwap(.checkRequested))
    await store.receive(\.bundleSwap.checked) { $0.bundleSwap.pending = "graphcoded:1:2" }
  }

  @Test
  func anUnchangedBundleSaysNothing() async {
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.updateClient.swappedBundleStamp = { nil }
    }
    await store.send(.bundleSwap(.checkRequested))
    await store.receive(\.bundleSwap.checked)
  }

  /// "Later" answers for *that* swap. Without the acknowledgement the prompt would come
  /// back every time the window was brought forward, which is nagging rather than news.
  @Test
  func laterDeclinesThisSwapAndNotEveryActivationAfterIt() async {
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.updateClient.swappedBundleStamp = { "graphcoded:1:2" }
    }
    await store.send(.bundleSwap(.checkRequested))
    await store.receive(\.bundleSwap.checked) { $0.bundleSwap.pending = "graphcoded:1:2" }
    await store.send(.bundleSwap(.relaunchDismissed)) {
      $0.bundleSwap.acknowledged = "graphcoded:1:2"
      $0.bundleSwap.pending = nil
    }

    await store.send(.bundleSwap(.checkRequested))
    await store.receive(\.bundleSwap.checked)
  }

  /// A *second* swap after the first was declined is news again — the helpers on disk
  /// moved on, so the stale window is staler than the one that was waved away.
  @Test
  func aSecondSwapIsNewsAgain() async {
    let store = TestStore(
      initialState: AppFeature.State(bundleSwap: BundleSwap(acknowledged: "graphcoded:1:2"))
    ) {
      AppFeature()
    } withDependencies: {
      $0.updateClient.swappedBundleStamp = { "graphcoded:1:3" }
    }
    await store.send(.bundleSwap(.checkRequested))
    await store.receive(\.bundleSwap.checked) { $0.bundleSwap.pending = "graphcoded:1:3" }
  }

  /// Nothing is asked while an install is running or a relaunch is already on offer:
  /// both end in the relaunch this prompt exists to ask for.
  @Test
  func anInstallInFlightIsNotInterrupted() async {
    let store = TestStore(initialState: AppFeature.State(updateInstallProgress: 0.4)) {
      AppFeature()
    } withDependencies: {
      $0.updateClient.swappedBundleStamp = { "graphcoded:1:2" }
    }
    await store.send(.bundleSwap(.checkRequested))

    let offered = TestStore(initialState: AppFeature.State(isUpdateReadyToRelaunch: true)) {
      AppFeature()
    } withDependencies: {
      $0.updateClient.swappedBundleStamp = { "graphcoded:1:2" }
    }
    await offered.send(.bundleSwap(.checkRequested))
  }

  /// The probe is three `stat`s and nothing else. Repeating `installIfNeeded` on every
  /// activation would shell out to launchctl on the main thread and, worse, install new
  /// helpers under a window whose own code was replaced — a new daemon serving an old
  /// app, which is a worse pairing than the stale one it replaced.
  @Test
  func anUnpackagedBuildHasNothingToCompare() {
    #expect(DaemonBootstrap.changedBundleStamp() == nil)
  }
}
