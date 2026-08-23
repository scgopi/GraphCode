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

  /// A release matching the given offer, for stubbing the re-check Install runs at
  /// consent time with a "nothing newer" answer.
  private func recheckRelease(matching offered: AvailableUpdate) throws -> UpdateRelease {
    try JSONDecoder().decode(
      UpdateRelease.self,
      from: Data(
        """
        {
          "tag_name": "\(offered.version)",
          "html_url": "https://example.com/releases/tag/\(offered.version)",
          "assets": [
            {
              "name": "graphcode-macos-arm64.dmg",
              "browser_download_url": "\(offered.downloadURL.absoluteString)"
            }
          ]
        }
        """.utf8))
  }

  /// The stubs every install test needs now that tapping Install asks the channel
  /// again before downloading.
  private func stubRecheck(
    _ dependencies: inout DependencyValues, returning releases: [UpdateRelease]
  ) {
    dependencies.updateClient.currentVersion = { "0.1.16-beta1" }
    dependencies.updateClient.channelOverride = { nil }
    dependencies.updateClient.allReleases = { releases }
  }

  @Test
  @MainActor
  func installDownloadsWithProgressAndOffersTheRelaunch() async throws {
    let (state, update) = try offeredState()
    let recheck = try recheckRelease(matching: update)
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      stubRecheck(&$0, returning: [recheck])
      $0.updateInstallClient.install = { dmg, progress in
        #expect(dmg == update.downloadURL)
        progress(0.5)
        progress(1)
      }
    }
    store.exhaustivity = .off

    await store.send(.updateAlertDismissed)
    await store.send(.updateInstallTapped)
    // Install asks about other open workspaces first (there are none here), so the work
    // starts on the action both answers arrive as.
    await store.receive(\.updateInstallConfirmed)
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
    let recheck = try recheckRelease(matching: update)
    let opened = URLsBox()
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      stubRecheck(&$0, returning: [recheck])
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
    let (state, update) = try offeredState()
    let recheck = try recheckRelease(matching: update)
    let installs = CounterBox()
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      stubRecheck(&$0, returning: [recheck])
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

  /// The stale-offer race (a release cut while the alert sat open): the app offered
  /// one version, a newer one shipped before Install was clicked, and installing the
  /// offer meant relaunching straight into another update alert. Install re-checks at
  /// consent time and downloads whatever is newest *now*.
  @Test
  @MainActor
  func installReChecksAndTakesAReleaseCutAfterTheOffer() async throws {
    let (state, offered) = try offeredState()
    let newer = try JSONDecoder().decode(
      UpdateRelease.self,
      from: Data(
        """
        {
          "tag_name": "0.1.16-beta3",
          "html_url": "https://example.com/releases/tag/0.1.16-beta3",
          "assets": [
            {
              "name": "graphcode-macos-arm64.dmg",
              "browser_download_url": "https://example.com/0.1.16-beta3/graphcode-macos-arm64.dmg"
            }
          ]
        }
        """.utf8))
    let installed = URLsBox()
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      stubRecheck(&$0, returning: [newer])
      $0.updateInstallClient.install = { dmg, _ in await installed.append(dmg) }
    }
    store.exhaustivity = .off

    await store.send(.updateAlertDismissed)
    await store.send(.updateInstallTapped)
    await store.receive(\.updateInstallResolved)
    await store.receive(\.updateInstallFinished)

    // The newer DMG was downloaded, and the state names the version actually
    // installed — the relaunch prompt must not claim the stale one.
    #expect(await installed.urls.first?.absoluteString.contains("0.1.16-beta3") == true)
    #expect(store.state.offeredUpdate?.version == "0.1.16-beta3")
    #expect(store.state.offeredUpdate != offered)
    #expect(store.state.isUpdateReadyToRelaunch)
  }
}
