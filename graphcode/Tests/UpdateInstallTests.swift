import ComposableArchitecture
import Foundation
import Testing

@testable import graphcode

/// Direct install (issue #37): the flow from the offer alert's Install Update through
/// download progress to the relaunch prompt, and the browser fallback when it fails.
/// Every test dismisses the alert before tapping — the order SwiftUI actually delivers
/// (#35) — so a regression to reading presentation state fails here, not in the field.
@Suite
struct UpdateInstallTests {

  private func offeredState() throws -> (AppFeature.State, AvailableUpdate) {
    let release = try JSONDecoder().decode(
      UpdateRelease.self,
      from: Data(
        """
        {
          "tag_name": "0.1.16-beta2",
          "html_url": "https://example.com/releases/tag/0.1.16-beta2",
          "assets": [
            {
              "name": "graphcode-macos-arm64.dmg",
              "browser_download_url": "https://example.com/0.1.16-beta2/graphcode-macos-arm64.dmg"
            }
          ]
        }
        """.utf8))
    let update = try #require(AppUpdate.available(current: "0.1.16-beta1", release: release))
    var state = AppFeature.State()
    state.availableUpdate = update
    state.offeredUpdate = update
    return (state, update)
  }

  @Test
  @MainActor
  func installDownloadsWithProgressAndOffersTheRelaunch() async throws {
    let (state, update) = try offeredState()
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.updateInstallClient.install = { dmg, progress in
        #expect(dmg == update.downloadURL)
        progress(0.5)
        progress(1)
      }
    }
    store.exhaustivity = .off

    await store.send(.updateAlertDismissed)
    await store.send(.updateInstallTapped)
    #expect(store.state.updateInstallProgress == 0)
    await store.receive(\.updateInstallFinished)

    // The bar is down, the relaunch prompt is up, and nothing reads as failed.
    #expect(store.state.updateInstallProgress == nil)
    #expect(store.state.isUpdateReadyToRelaunch)
    #expect(store.state.updateInstallFailure == nil)
  }

  private actor CounterBox {
    var hits = 0
    func bump() { hits += 1 }
  }

  @Test
  @MainActor
  func relaunchNowRelaunchesAndLaterJustWaits() async throws {
    var (state, _) = try offeredState()
    state.availableUpdate = nil
    state.isUpdateReadyToRelaunch = true

    let relaunches = CounterBox()
    func store() -> TestStoreOf<AppFeature> {
      let store = TestStore(initialState: state) {
        AppFeature()
      } withDependencies: {
        $0.updateInstallClient.relaunch = { await relaunches.bump() }
      }
      store.exhaustivity = .off
      return store
    }

    let later = store()
    await later.send(.updateRelaunchDismissed)
    #expect(!later.state.isUpdateReadyToRelaunch)
    #expect(await relaunches.hits == 0)

    let now = store()
    await now.send(.updateRelaunchTapped)
    await now.finish()
    #expect(!now.state.isUpdateReadyToRelaunch)
    #expect(await relaunches.hits == 1)
  }

  @Test
  @MainActor
  func aFailedInstallExplainsItselfAndTheBrowserFallbackStillWorks() async throws {
    let (state, update) = try offeredState()
    let opened = URLsBox()
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.updateInstallClient.install = { _, _ in
        throw UpdateInstallFailure.signatureRejected
      }
      $0.openURL = OpenURLEffect { url in
        await opened.append(url)
        return true
      }
    }
    store.exhaustivity = .off

    await store.send(.updateAlertDismissed)
    await store.send(.updateInstallTapped)
    await store.receive(\.updateInstallFinished)

    #expect(store.state.updateInstallProgress == nil)
    #expect(!store.state.isUpdateReadyToRelaunch)
    #expect(
      store.state.updateInstallFailure
        == UpdateInstallFailure.signatureRejected.localizedDescription)

    // The failure alert's fallback: the same browser download as before #37.
    await store.send(.updateDownloadTapped)
    await store.finish()
    #expect(store.state.updateInstallFailure == nil)
    #expect(await opened.urls == [update.downloadURL])
  }

  private actor URLsBox {
    var urls: [URL] = []
    func append(_ url: URL) { urls.append(url) }
  }

  @Test
  @MainActor
  func aSecondInstallTapWhileOneRunsIsIgnored() async throws {
    let (state, _) = try offeredState()
    let installs = CounterBox()
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.updateInstallClient.install = { _, _ in
        await installs.bump()
        try await Task.sleep(for: .seconds(100))
      }
    }
    store.exhaustivity = .off

    await store.send(.updateInstallTapped)
    await store.send(.updateInstallTapped)
    #expect(await installs.hits == 1)
    await store.skipInFlightEffects()
  }
}
