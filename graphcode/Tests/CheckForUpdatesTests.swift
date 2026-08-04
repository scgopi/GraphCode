import ComposableArchitecture
import Foundation
import Testing

@testable import graphcode

/// Check for Updates (issue #27): the version comparison the offer hangs on, the slice
/// of GitHub's release JSON the check reads, and the flow from the menu item to the two
/// alerts `AppView` hosts.
@Suite
struct CheckForUpdatesTests {

  // MARK: - Versions

  @Test
  func aStableTagAndABundleVersionAreTheSameVersion() {
    // The two spellings this app actually ships: `v0.1.14` on the tag,
    // `0.1.14` in the bundle.
    #expect(AppVersion("v0.1.14") == AppVersion("0.1.14"))
  }

  private func version(_ string: String) throws -> AppVersion {
    try #require(AppVersion(string))
  }

  @Test
  func versionsCompareNumericallyNotLexicographically() throws {
    // "0.1.9" > "0.1.14" as strings — the released history already contains both, so
    // this is the comparison a naive check would get wrong.
    #expect(try version("0.1.9") < version("0.1.14"))
    #expect(try version("0.1.99") < version("0.2"))
    // A shorter version pads with zeros rather than sorting by length.
    #expect(try version("0.1.14") < version("0.1.14.1"))
    #expect(try !(version("0.1.14") < version("0.1.14")))
  }

  @Test
  func aBetaPrecedesItsOwnReleaseAndBetasOrderByNumber() throws {
    // Beta tags carry no `v` (see the Makefile's TAG_PREFIX) and sort before the
    // release they are a beta of; beta10 after beta2 is the numeric half again.
    #expect(try version("0.1.14-beta3") < version("v0.1.14"))
    #expect(try version("0.1.14-beta2") < version("0.1.14-beta10"))
    #expect(try version("v0.1.12") < version("0.1.14-beta1"))
  }

  @Test
  func garbageIsNotAVersion() {
    #expect(AppVersion("main") == nil)
    #expect(AppVersion("") == nil)
    #expect(AppVersion("1.two.3") == nil)
  }

  // MARK: - The channel

  @Test
  func theInstalledVersionPicksTheChannelAndAnOverrideWins() {
    // A beta build follows betas, a stable install follows stables — no setting needed.
    #expect(UpdateChannel.channel(for: "0.1.15-beta2", override: nil) == .beta)
    #expect(UpdateChannel.channel(for: "0.1.15", override: nil) == .stable)
    // The explicit setting beats the version in both directions.
    #expect(UpdateChannel.channel(for: "0.1.15", override: "beta") == .beta)
    #expect(UpdateChannel.channel(for: "0.1.15-beta2", override: "stable") == .stable)
    // Garbage in the default and an unversioned dev build both fall back safely.
    #expect(UpdateChannel.channel(for: "0.1.15", override: "nightly") == .stable)
    #expect(UpdateChannel.channel(for: "unversioned", override: nil) == .stable)
  }

  // MARK: - The release JSON

  private func release(_ json: String) throws -> UpdateRelease {
    try JSONDecoder().decode(UpdateRelease.self, from: Data(json.utf8))
  }

  /// The shape `GET /repos/scgopi/GraphCode/releases/latest` actually answers with,
  /// trimmed to the keys the check reads plus a few it must ignore.
  private let latestReleaseJSON = """
    {
      "tag_name": "v0.2.0",
      "name": "v0.2.0 — a bigger canvas",
      "html_url": "https://example.com/releases/tag/v0.2.0",
      "prerelease": false,
      "assets": [
        {
          "name": "graphcode-macos-arm64.dmg.sha256",
          "browser_download_url": "https://example.com/v0.2.0/graphcode-macos-arm64.dmg.sha256"
        },
        {
          "name": "graphcode-macos-arm64.dmg",
          "browser_download_url": "https://example.com/v0.2.0/graphcode-macos-arm64.dmg"
        }
      ]
    }
    """

  @Test
  func theReleaseJSONDecodesToTagNotesAndTheExactDMG() throws {
    let release = try release(latestReleaseJSON)
    #expect(release.tagName == "v0.2.0")
    #expect(release.displayVersion == "0.2.0")
    // The exact asset `release-dmg` uploads — not the `.sha256` beside it, even though
    // that one's name also contains ".dmg".
    #expect(
      release.dmgDownloadURL?.absoluteString
        == "https://example.com/v0.2.0/graphcode-macos-arm64.dmg")
  }

  @Test
  func aRenamedDMGStillDownloadsAndNoDMGFallsBackToTheReleasePage() throws {
    let renamed = try release(
      """
      {
        "tag_name": "v0.2.0",
        "html_url": "https://example.com/releases/tag/v0.2.0",
        "assets": [
          {
            "name": "GraphCode-0.2.0.dmg",
            "browser_download_url": "https://example.com/GraphCode-0.2.0.dmg"
          }
        ]
      }
      """)
    #expect(renamed.dmgDownloadURL?.absoluteString == "https://example.com/GraphCode-0.2.0.dmg")

    let bare = try release(
      """
      {
        "tag_name": "v0.2.0",
        "html_url": "https://example.com/releases/tag/v0.2.0",
        "assets": []
      }
      """)
    #expect(bare.dmgDownloadURL == nil)
    let update = AppUpdate.available(current: "0.1.14", release: bare)
    // No DMG is a mis-shaped release, not a dead end — the button leads somewhere the
    // human can still get the update.
    #expect(update?.downloadURL == bare.htmlURL)
  }

  // MARK: - The decision

  @Test
  func aNewerReleaseIsAnUpdateAndTheSameOrOlderIsNot() throws {
    let release = try release(latestReleaseJSON)
    let update = AppUpdate.available(current: "0.1.14", release: release)
    #expect(update?.version == "0.2.0")
    #expect(update?.currentVersion == "0.1.14")
    #expect(update?.downloadURL == release.dmgDownloadURL)
    #expect(update?.releaseNotesURL == release.htmlURL)

    #expect(AppUpdate.available(current: "0.2.0", release: release) == nil)
    // Running ahead of the newest release — a build from main — is not an update either.
    #expect(AppUpdate.available(current: "0.3.0", release: release) == nil)
  }

  @Test
  func anUnparsableVersionOnEitherSideOffersNothing() throws {
    // A dev build with no real version should never be nagged, and a malformed tag is
    // GitHub telling us nothing trustworthy.
    let release = try release(latestReleaseJSON)
    #expect(AppUpdate.available(current: "unversioned", release: release) == nil)

    let badTag = try self.release(
      """
      {
        "tag_name": "latest",
        "html_url": "https://example.com/releases/tag/latest",
        "assets": []
      }
      """)
    #expect(AppUpdate.available(current: "0.1.14", release: badTag) == nil)
  }

  /// The releases list as the beta channel sees it: the newest beta, its predecessor,
  /// and the stable line's newest, in GitHub's newest-first order.
  private let releasesListJSON = """
    [
      {
        "tag_name": "0.1.15-beta2",
        "html_url": "https://example.com/releases/tag/0.1.15-beta2",
        "prerelease": true,
        "assets": [
          {
            "name": "graphcode-macos-arm64.dmg",
            "browser_download_url": "https://example.com/0.1.15-beta2/graphcode-macos-arm64.dmg"
          }
        ]
      },
      {
        "tag_name": "0.1.15-beta1",
        "html_url": "https://example.com/releases/tag/0.1.15-beta1",
        "prerelease": true,
        "assets": []
      },
      {
        "tag_name": "v0.1.14",
        "html_url": "https://example.com/releases/tag/v0.1.14",
        "prerelease": false,
        "assets": []
      }
    ]
    """

  private func releasesList() throws -> [UpdateRelease] {
    try JSONDecoder().decode([UpdateRelease].self, from: Data(releasesListJSON.utf8))
  }

  @Test
  func aBetaInstallSeesTheNewerBetaAndItsDMG() throws {
    // The issue's acceptance case: 0.1.15-beta1 is walked to 0.1.15-beta2.
    let update = try AppUpdate.available(current: "0.1.15-beta1", releases: releasesList())
    #expect(update?.version == "0.1.15-beta2")
    #expect(
      update?.downloadURL.absoluteString
        == "https://example.com/0.1.15-beta2/graphcode-macos-arm64.dmg")

    #expect(try AppUpdate.available(current: "0.1.15-beta2", releases: releasesList()) == nil)
  }

  @Test
  func aStableThatClosesTheBetaLineWinsOverTheBetas() throws {
    // Once v0.1.15 ships it outranks its own betas — the beta install is walked to
    // the stable, not left on the prerelease line.
    var releases = try releasesList()
    releases.append(
      try release(
        """
        {
          "tag_name": "v0.1.15",
          "html_url": "https://example.com/releases/tag/v0.1.15",
          "assets": []
        }
        """))
    let update = AppUpdate.available(current: "0.1.15-beta2", releases: releases)
    #expect(update?.version == "0.1.15")
  }

  @Test
  func unversionedTagsDoNotCompeteAndAnEmptyListOffersNothing() throws {
    var releases = try releasesList()
    releases.insert(
      try release(
        """
        {
          "tag_name": "nightly",
          "html_url": "https://example.com/releases/tag/nightly",
          "assets": []
        }
        """), at: 0)
    let update = AppUpdate.available(current: "0.1.15-beta1", releases: releases)
    #expect(update?.version == "0.1.15-beta2")

    #expect(AppUpdate.available(current: "0.1.15-beta1", releases: []) == nil)
  }

  // MARK: - The flow

  private func fixtureRelease() throws -> UpdateRelease {
    try release(latestReleaseJSON)
  }

  @Test
  @MainActor
  func theMenuItemFindsAnUpdateAndOffersIt() async throws {
    let release = try fixtureRelease()
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.updateClient.latestRelease = { release }
      $0.updateClient.currentVersion = { "0.1.14" }
    }
    store.exhaustivity = .off

    await store.send(.checkForUpdatesTapped)
    #expect(store.state.isCheckingForUpdates)
    await store.receive(\.updateCheckCompleted)

    #expect(!store.state.isCheckingForUpdates)
    #expect(store.state.availableUpdate?.version == "0.2.0")
    #expect(store.state.updateNotice == nil)
  }

  @Test
  @MainActor
  func aBetaBuildChecksTheReleasesListAndIsOfferedTheNewerBeta() async throws {
    // `latestRelease` keeps the throwing test default — if the beta channel touched
    // GitHub's stable answer at all, this test would fail with a check error.
    let releases = try releasesList()
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.updateClient.allReleases = { releases }
      $0.updateClient.currentVersion = { "0.1.15-beta1" }
    }
    store.exhaustivity = .off

    await store.send(.checkForUpdatesTapped)
    await store.receive(\.updateCheckCompleted)

    #expect(store.state.availableUpdate?.version == "0.1.15-beta2")
    #expect(store.state.updateNotice == nil)
  }

  @Test
  @MainActor
  func aStableInstallOptedIntoBetaIsOfferedTheBetaToo() async throws {
    let releases = try releasesList()
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.updateClient.allReleases = { releases }
      $0.updateClient.currentVersion = { "0.1.14" }
      $0.updateClient.channelOverride = { "beta" }
    }
    store.exhaustivity = .off

    await store.send(.checkForUpdatesTapped)
    await store.receive(\.updateCheckCompleted)

    #expect(store.state.availableUpdate?.version == "0.1.15-beta2")
  }

  @Test
  @MainActor
  func beingUpToDateSaysSoInsteadOfOffering() async throws {
    let release = try fixtureRelease()
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.updateClient.latestRelease = { release }
      $0.updateClient.currentVersion = { "0.2.0" }
    }
    store.exhaustivity = .off

    await store.send(.checkForUpdatesTapped)
    await store.receive(\.updateCheckCompleted)

    #expect(store.state.availableUpdate == nil)
    #expect(store.state.updateNotice == .upToDate(current: "0.2.0"))

    await store.send(.updateNoticeDismissed)
    #expect(store.state.updateNotice == nil)
  }

  @Test
  @MainActor
  func aFailedCheckExplainsItselfInsteadOfStayingSilent() async {
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.updateClient.latestRelease = { throw UpdateCheckFailure.requestFailed(status: 503) }
    }
    store.exhaustivity = .off

    await store.send(.checkForUpdatesTapped)
    await store.receive(\.updateCheckCompleted)

    #expect(store.state.availableUpdate == nil)
    #expect(store.state.updateNotice?.title == "Couldn't check for updates")
    // The check is done either way — the menu item must come back.
    #expect(!store.state.isCheckingForUpdates)
  }

  private actor OpenedURLsBox {
    var urls: [URL] = []
    func append(_ url: URL) { urls.append(url) }
  }

  @Test
  @MainActor
  func downloadStillWorksAfterSwiftUIAlreadyDismissedTheAlert() async throws {
    // The order SwiftUI actually delivers (#35): the alert's presentation binding is
    // cleared — sending updateAlertDismissed — *before* the tapped button's action
    // runs. The download must survive that, which is what `offeredUpdate` is for.
    let release = try fixtureRelease()
    let update = try #require(AppUpdate.available(current: "0.1.14", release: release))
    var state = AppFeature.State()
    state.availableUpdate = update
    state.offeredUpdate = update

    let opened = OpenedURLsBox()
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.openURL = OpenURLEffect { url in
        await opened.append(url)
        return true
      }
    }
    store.exhaustivity = .off

    await store.send(.updateAlertDismissed)
    await store.send(.updateDownloadTapped)
    await store.finish()

    #expect(store.state.availableUpdate == nil)
    #expect(await opened.urls == [update.downloadURL])
  }

  @Test
  @MainActor
  func laterDismissesWithoutOpeningAnything() async throws {
    let release = try fixtureRelease()
    var state = AppFeature.State()
    state.availableUpdate = AppUpdate.available(current: "0.1.14", release: release)

    let store = TestStore(initialState: state) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.updateAlertDismissed)
    #expect(store.state.availableUpdate == nil)
  }
}
