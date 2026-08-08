import ComposableArchitecture
import Foundation
import Testing

@testable import graphcode

/// The sidebar update banner's reducer half: a silent launch check that only ever
/// *raises* the banner, and a banner tap that opens the existing offer alert.
@Suite
struct SidebarUpdateBannerTests {
  private func release(tag: String) throws -> UpdateRelease {
    let json = """
      {
        "tag_name": "\(tag)",
        "html_url": "https://github.com/scgopi/GraphCode/releases/tag/\(tag)",
        "assets": [
          {
            "name": "graphcode-macos-arm64.dmg",
            "browser_download_url": "https://example.com/\(tag).dmg"
          }
        ]
      }
      """
    return try JSONDecoder().decode(UpdateRelease.self, from: Data(json.utf8))
  }

  @Test
  @MainActor
  func theLaunchCheckRaisesTheBannerWithoutOpeningAnAlert() async throws {
    let newer = try release(tag: "v0.2.0")
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.updateClient.latestRelease = { newer }
      $0.updateClient.currentVersion = { "0.1.14" }
    }
    store.exhaustivity = .off

    await store.send(.checkForUpdatesInBackground)
    await store.receive(\.updateFoundInBackground)

    // The banner's source is set; the alert is not auto-presented, and no "up to
    // date" / "couldn't check" notice is raised.
    #expect(store.state.offeredUpdate?.version == "0.2.0")
    #expect(store.state.availableUpdate == nil)
    #expect(store.state.updateNotice == nil)
    #expect(!store.state.isCheckingForUpdates)
  }

  @Test
  @MainActor
  func anUpToDateLaunchCheckStaysCompletelyQuiet() async throws {
    let same = try release(tag: "v0.2.0")
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.updateClient.latestRelease = { same }
      $0.updateClient.currentVersion = { "0.2.0" }
    }
    store.exhaustivity = .off

    await store.send(.checkForUpdatesInBackground)
    await store.receive(\.updateFoundInBackground)

    #expect(store.state.offeredUpdate == nil)
    #expect(store.state.availableUpdate == nil)
    // No banner, and — unlike the menu item — no alert either way.
    #expect(store.state.updateNotice == nil)
  }

  @Test
  @MainActor
  func aFailedLaunchCheckIsSilentAndKeepsAnyExistingOffer() async throws {
    let update = try #require(
      AppUpdate.available(current: "0.1.14", release: release(tag: "v0.2.0")))
    var state = AppFeature.State()
    state.offeredUpdate = update  // an earlier check already found it

    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.updateClient.latestRelease = { throw UpdateCheckFailure.requestFailed(status: 503) }
      $0.updateClient.currentVersion = { "0.1.14" }
    }
    store.exhaustivity = .off

    await store.send(.checkForUpdatesInBackground)
    await store.receive(\.updateFoundInBackground)

    // A flaky launch check neither nags nor lowers a banner an earlier check raised.
    #expect(store.state.updateNotice == nil)
    #expect(store.state.offeredUpdate?.version == "0.2.0")
  }

  @Test
  @MainActor
  func tappingTheBannerPresentsTheOfferAlert() async throws {
    let update = try #require(
      AppUpdate.available(current: "0.1.14", release: release(tag: "v0.2.0")))
    var state = AppFeature.State()
    state.offeredUpdate = update

    let store = TestStore(initialState: state) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.updateBannerTapped)
    // The same alert the menu's successful check raises — UpdateDialogs keys on this.
    #expect(store.state.availableUpdate?.version == "0.2.0")
  }
}
