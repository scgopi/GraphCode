import Foundation
import Testing

@testable import GraphcodeKit

/// What makes drag-to-Applications a complete install: a packaged app carries `graphcoded`
/// and `zmx` inside itself and puts them in place on first launch.
///
/// These exercise the decisions rather than the copying — installing for real would move
/// the developer's own daemon, which is exactly the accident this must never cause on a
/// build run from Xcode.
@Suite
struct DaemonBootstrapTests {
  private func makeBundleDirectory(helpers: [String]) -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("graphcode-tests-\(UUID().uuidString)", isDirectory: true)
    let binary = root.appendingPathComponent("bin", isDirectory: true)
    try? FileManager.default.createDirectory(at: binary, withIntermediateDirectories: true)
    for name in helpers {
      let url = binary.appendingPathComponent(name)
      FileManager.default.createFile(
        atPath: url.path, contents: Data(name.utf8),
        attributes: [.posixPermissions: 0o755])
    }
    return root
  }

  @Test
  func aBuildWithNoBundledHelpersIsLeftAlone() {
    // The case that matters most: running from Xcode must not touch a developer's own
    // `make daemon-install` setup, which usually points at DerivedData.
    #expect(DaemonBootstrap.bundledHelperDirectory(in: Bundle(for: BundleMarker.self)) == nil)
  }

  @Test
  func aPartiallyPopulatedBundleIsNotTreatedAsPackaged() {
    // Half an install is worse than none — it would load a launch agent pointing at a
    // daemon that was never copied.
    let root = makeBundleDirectory(helpers: ["graphcoded"])
    defer { try? FileManager.default.removeItem(at: root) }
    let binary = root.appendingPathComponent("bin")

    // One helper present, two required — the stamp sees it, but it must not count as a
    // packaged build.
    #expect(DaemonBootstrap.stamp(forHelpersIn: binary).contains("graphcoded"))
    #expect(!DaemonBootstrap.stamp(forHelpersIn: binary).contains("zmx"))
    if let bundle = Bundle(url: root) {
      #expect(DaemonBootstrap.bundledHelperDirectory(in: bundle) == nil)
    }
  }

  @Test
  func theStampChangesWhenAHelperChanges() {
    // This is what makes an app update carry a daemon update: same helpers, same stamp,
    // no work; different bytes, new stamp, reinstall.
    let root = makeBundleDirectory(helpers: ["graphcoded", "zmx"])
    defer { try? FileManager.default.removeItem(at: root) }
    let binary = root.appendingPathComponent("bin")

    let before = DaemonBootstrap.stamp(forHelpersIn: binary)
    #expect(before.contains("graphcoded"))
    #expect(before.contains("zmx"))
    #expect(DaemonBootstrap.stamp(forHelpersIn: binary) == before)

    try? Data("a considerably longer replacement".utf8)
      .write(to: binary.appendingPathComponent("zmx"))
    #expect(DaemonBootstrap.stamp(forHelpersIn: binary) != before)
  }

  @Test
  func aMissingInstalledHelperDefeatsTheUpToDateShortCircuit() {
    // The 0.1.9-beta1 failure: an install that lost a helper after the stamp was
    // written reported itself up to date forever — no daemon, no sessions, and an app
    // that read as "corrupted". The stamp answers "which bundle was installed";
    // only the bin directory can answer "is it still there".
    let root = makeBundleDirectory(helpers: ["graphcoded", "zmx", "graphcode"])
    defer { try? FileManager.default.removeItem(at: root) }
    let binary = root.appendingPathComponent("bin")

    #expect(DaemonBootstrap.helpersInstalled(in: binary))

    try? FileManager.default.removeItem(at: binary.appendingPathComponent("zmx"))
    #expect(!DaemonBootstrap.helpersInstalled(in: binary))
  }

  @Test
  func installingAHelperClearsItsQuarantineFlag() {
    // The other-machine failure: `copyItem` faithfully carries `com.apple.quarantine`
    // from a downloaded bundle into ~/.graphcode/bin, and launchd's first spawn of a
    // quarantined daemon is met with "Apple could not verify 'graphcoded' is free of
    // malware". The build machine never sees it — its quarantine is already approved.
    let root = makeBundleDirectory(helpers: ["graphcoded"])
    defer { try? FileManager.default.removeItem(at: root) }
    let helper = root.appendingPathComponent("bin/graphcoded")

    let quarantine = "0083;00000000;Safari;"
    setxattr(helper.path, "com.apple.quarantine", quarantine, quarantine.utf8.count, 0, 0)
    #expect(getxattr(helper.path, "com.apple.quarantine", nil, 0, 0, 0) > 0)

    DaemonBootstrap.clearQuarantine(helper)
    #expect(getxattr(helper.path, "com.apple.quarantine", nil, 0, 0, 0) == -1)

    // Clearing a file that never had the flag must be harmless — that's every install
    // performed on the machine the release was built on.
    DaemonBootstrap.clearQuarantine(helper)
  }

  @Test
  func theLaunchAgentPointsAtTheInstalledDaemonNotTheBundle() {
    // Pointing launchd inside the app bundle would break the moment the app is replaced
    // or moved, and would keep a mounted disk image busy.
    let plist = DaemonBootstrap.launchAgentPlist(
      daemonPath: "/Users/x/.graphcode/bin/graphcoded", supportDirectory: "/Users/x/.graphcode",
      workspace: .default)

    #expect(plist["Label"] as? String == "dev.graphcode.graphcoded")
    #expect(plist["ProgramArguments"] as? [String] == ["/Users/x/.graphcode/bin/graphcoded"])
    #expect(plist["RunAtLoad"] as? Bool == true)
    #expect(plist["KeepAlive"] as? Bool == true)
    #expect(plist["StandardErrorPath"] as? String == "/Users/x/.graphcode/graphcoded.err.log")

    // It has to serialize — a malformed agent fails silently at load time.
    #expect(
      (try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0))
        != nil)
  }

  @Test
  func theLaunchAgentNamesTheAppSoMacOSDoesNotNameTheDeveloper() {
    // Left out, macOS labels the background item with the signing certificate's name and
    // tells the user "Software from <a person they have never heard of> can run in the
    // background".
    let plist = DaemonBootstrap.launchAgentPlist(
      daemonPath: "/Users/x/.graphcode/bin/graphcoded", supportDirectory: "/Users/x/.graphcode",
      workspace: .default)

    #expect(plist["AssociatedBundleIdentifiers"] as? [String] == ["dev.graphcode.app"])
  }

  @Test
  func anAgentFromAnEarlierBuildIsNotMistakenForACurrentOne() throws {
    // The upgrade path for the naming fix above. Judging the agent by its existence alone
    // left the old one in place on every machine whose helpers happened not to change.
    let directory = makeBundleDirectory(helpers: [])
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("agent.plist")
    let expected = DaemonBootstrap.launchAgentPlist(
      daemonPath: "/Users/x/.graphcode/bin/graphcoded", supportDirectory: "/Users/x/.graphcode",
      workspace: .default)

    #expect(!DaemonBootstrap.launchAgentIsCurrent(at: url, expected: expected))

    var previous = expected
    previous["AssociatedBundleIdentifiers"] = nil
    try PropertyListSerialization.data(fromPropertyList: previous, format: .xml, options: 0)
      .write(to: url)
    #expect(!DaemonBootstrap.launchAgentIsCurrent(at: url, expected: expected))

    try PropertyListSerialization.data(fromPropertyList: expected, format: .xml, options: 0)
      .write(to: url)
    #expect(DaemonBootstrap.launchAgentIsCurrent(at: url, expected: expected))
  }

  @Test
  func theDefaultWorkspacesAgentIsUnchangedAndANamedOnesCarriesItsDirectory() {
    // Two halves of one promise. launchd starts an agent with its own minimal
    // environment, so a named workspace's daemon has to be *told* where to look or it
    // computes `~/.graphcode` and serves the default workspace's graphs under the second
    // workspace's label. And the default workspace must gain nothing at all: an extra key
    // there would make `launchAgentIsCurrent` call every existing install stale and bounce
    // a daemon that was running perfectly well.
    let standard = DaemonBootstrap.launchAgentPlist(
      daemonPath: "/Users/x/.graphcode/bin/graphcoded", supportDirectory: "/Users/x/.graphcode",
      workspace: .default)
    #expect(standard["EnvironmentVariables"] as? [String: String] == nil)
    #expect(standard["Label"] as? String == "dev.graphcode.graphcoded")

    let named = DaemonBootstrap.launchAgentPlist(
      daemonPath: "/Users/x/.graphcode-work/bin/graphcoded",
      supportDirectory: "/Users/x/.graphcode-work",
      workspace: Workspace(slug: "work", url: URL(fileURLWithPath: "/Users/x/.graphcode-work")))
    #expect(named["Label"] as? String == "dev.graphcode.graphcoded.work")
    #expect(
      named["EnvironmentVariables"] as? [String: String]
        == ["GRAPHCODE_SUPPORT_DIR": "/Users/x/.graphcode-work"])
    #expect(named["StandardOutPath"] as? String == "/Users/x/.graphcode-work/graphcoded.log")
    // Still the app's own agent, whichever workspace it serves — this is what keeps
    // macOS from naming the background item after the signing certificate.
    #expect(named["AssociatedBundleIdentifiers"] as? [String] == ["dev.graphcode.app"])
    #expect(
      (try? PropertyListSerialization.data(fromPropertyList: named, format: .xml, options: 0))
        != nil)
  }

  @Test
  func theLoadedCheckAsksLaunchdAboutThisUsersOwnAgent() {
    // A domain target naming the wrong uid answers about someone else's login session,
    // which on a shared machine is a probe that can only ever say "not loaded".
    #expect(DaemonBootstrap.domainTarget == "gui/\(getuid())")
    #expect(DaemonBootstrap.serviceTarget == "gui/\(getuid())/dev.graphcode.graphcoded")

    var asked: [[String]] = []
    _ = DaemonBootstrap.daemonIsLoaded { arguments in
      asked.append(arguments)
      return 0
    }
    #expect(asked == [["print", "gui/\(getuid())/dev.graphcode.graphcoded"]])
  }

  @Test
  func anAgentLaunchdHasLostReadsAsNotLoaded() {
    // The whole of issue #152: the stamp, the helpers and the plist all still say the
    // install is good, so the only thing that can notice a daemon dropping out of
    // launchd — a reboot the legacy-loaded agent did not survive — is a non-zero exit
    // from `print`.
    #expect(DaemonBootstrap.daemonIsLoaded { _ in 0 })
    #expect(!DaemonBootstrap.daemonIsLoaded { _ in 113 })
    #expect(!DaemonBootstrap.daemonIsLoaded { _ in -1 })
  }

  @Test
  func launchctlReportsAMissingServiceAsAFailure() {
    // Pins the exit-code contract the check above rests on against the real tool: a
    // label no one has ever loaded must not come back as zero, or the self-heal is a
    // branch that never runs.
    #expect(
      DaemonBootstrap.launchctlStatus(
        ["print", "gui/\(getuid())/dev.graphcode.definitely-not-a-real-agent"]) != 0)
  }
}

/// Anchors `Bundle(for:)` on the test bundle, which has no embedded helpers.
private final class BundleMarker {}
