import Foundation
import Testing

@testable import GraphcodeKit

/// Codex's presence, which is the awkward one of the three.
///
/// **What was verified against the real CLI, offline:** `codex --strict-config` rejects an
/// invented config field outright ("unknown configuration field `totally`") and accepts
/// `notify=[…]`, so the override this builds is a real key and not a guess. `-c/--config`
/// is documented in `codex --help`, and `agent-turn-complete` is the event `notify` fires
/// on.
///
/// **What could not be verified, and why:** the installed Codex is logged out (its refresh
/// token is spent), so no session could be run to watch `notify` actually fire. A
/// hand-built `hooks.json` under `hooks.managed_dir` was tried as the richer alternative
/// and did *not* fire, which is exactly why this uses `notify` and not that: the hook
/// file's schema is undocumented, and `BackendCapabilities` is explicit that a capability
/// claimed on a hunch is what `isSpiked` exists to prevent.
@Suite
struct CodexPresenceTests {
  private let zmx = "/Users/someone/.graphcode/bin/zmx"

  @Test
  func theTurnEndIsReportedThroughTheOneChannelCodexHas() {
    let override = PresenceHooks.codexNotifyOverride(zmxPath: zmx)

    #expect(override.hasPrefix("notify=["))
    #expect(override.contains("presence=idle"))
    // Same session-owned label store the other two backends report into, so one reader
    // serves all three.
    #expect(override.contains(#"$ZMX_SESSION"#))
  }

  @Test
  func theOverrideIsValidTOMLForAnAwkwardPath() {
    // The value is TOML parsed out of one argv element, so the inner quotes around
    // `$ZMX_SESSION` have to survive as escapes rather than closing the string early.
    let override = PresenceHooks.codexNotifyOverride(zmxPath: "/Users/o'brien/bin/zmx")

    #expect(override.contains(#"\"$ZMX_SESSION\""#))
    // Two layers, and the doubled backslash is both of them doing their job: shell
    // quoting turns the apostrophe into `'\''`, then TOML escapes that backslash to
    // `\\`. Codex decodes the TOML back to `'\''`, which is what the shell must see.
    #expect(override.contains(#"o'\\''brien"#))
    // Three array elements: the program, its flag, and the script.
    #expect(override.hasPrefix(#"notify=["/bin/sh","-c",""#))
    #expect(override.hasSuffix("]"))
  }

  @Test
  func codexTakesTheFlagAndNothingMeantForTheOthers() {
    let arguments = CLISessionBackendKind.codex.presenceArguments(
      hooksFile: URL(fileURLWithPath: "/tmp/hooks.json"),
      sessionName: "graphcode-A", zmxPath: zmx)

    #expect(arguments.first == "-c")
    #expect(arguments.count == 2)
    // Codex has no `--settings` to layer hooks into and no `--name` to label a session.
    #expect(!arguments.contains("--settings"))
    #expect(!arguments.contains("--name"))
  }

  @Test
  func nowhereToReportMeansNoFlagRatherThanABrokenOne() {
    // A remote session, or a machine with no zmx: the override would name a binary that
    // isn't there, and Codex would run it once per turn forever.
    #expect(
      CLISessionBackendKind.codex.presenceArguments(
        hooksFile: nil, sessionName: "graphcode-A", zmxPath: nil) == [])
  }

  @Test
  func eachBackendGetsOnlyItsOwnMechanism() {
    // One function, three answers — the point being that the three CLIs genuinely differ
    // here and the code should not pretend otherwise.
    let file = URL(fileURLWithPath: "/tmp/hooks.json")
    let all = CLISessionBackendKind.allCases.map {
      $0.presenceArguments(hooksFile: file, sessionName: "graphcode-A", zmxPath: zmx).first
    }

    #expect(Set(all.compactMap { $0 }) == ["--settings", "--name", "-c"])
  }

  @Test
  func theOverrideRidesOnARealLaunch() throws {
    let node = LoopNode(
      title: "Ship it", loopType: .goalBased, goal: GoalSpec(summary: "Tests pass"),
      backend: .codex, state: .running)
    let arguments = try #require(ZmxSessionLauncher.arguments(forNode: node))

    // Only meaningful on a machine that has zmx to report into — which is every machine
    // that can run a loop at all, since the session itself is a zmx session.
    if ZmxLocator.isInstalled {
      #expect(arguments.contains { $0.hasPrefix("notify=[") })
    }
    #expect(arguments.contains(#"exec codex "$@""#))
  }

  @Test
  func theLaunchStillFitsInATypedCommandLine() throws {
    // `zmx` types the launch command into a tty that discards everything past MAX_CANON,
    // and this override is the longest single argument graphcode adds to a Codex launch.
    let node = LoopNode(
      title: "Ship it", loopType: .goalBased,
      goal: GoalSpec(summary: "Tests pass"), backend: .codex, state: .running)
    let arguments = try #require(ZmxSessionLauncher.arguments(forNode: node))

    #expect(ZmxSessionLauncher.fitsInATypedCommandLine(arguments))
  }
}
