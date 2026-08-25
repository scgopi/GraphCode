import Foundation
import Testing

@testable import GraphcodeKit

/// Keeping the Mac awake while loops run — the assertion `graphcoded` holds so unattended
/// work does not stall on a machine that went to sleep, and the setting that gates it.
@Suite
struct AwakeAssertionTests {
  @Test
  func nothingIsHeldWhileTheSettingIsOff() {
    #expect(!AwakeAssertion.shouldStayAwake(runningLoops: 3, enabled: false))
    #expect(!AwakeAssertion.shouldStayAwake(runningLoops: 0, enabled: false))
  }

  /// The assertion follows the work, not the daemon: an enabled machine with nothing
  /// running sleeps exactly as it did before this existed.
  @Test
  func theAssertionFollowsTheRunningLoops() {
    #expect(!AwakeAssertion.shouldStayAwake(runningLoops: 0, enabled: true))
    #expect(AwakeAssertion.shouldStayAwake(runningLoops: 1, enabled: true))
    #expect(AwakeAssertion.shouldStayAwake(runningLoops: 12, enabled: true))
  }

  /// Off by default. An update must never start holding a power assertion on a machine
  /// whose owner did not ask for it.
  @Test
  func theSettingIsOffUntilSomebodyAsks() {
    #expect(!GraphcodeSettings().keepsMacAwakeWhileLoopsRun)
  }

  /// A settings file written before this existed decodes with the feature off rather than
  /// failing the whole read — the same tolerance every other added key gets.
  @Test
  func aSettingsFileFromBeforeTheFeatureKeepsItOff() throws {
    let older = Data(#"{"defaultBackend":"claudeCode","summarisesLoops":true}"#.utf8)
    let settings = try JSONDecoder().decode(GraphcodeSettings.self, from: older)
    #expect(!settings.keepsMacAwakeWhileLoopsRun)
    #expect(settings.summarisesLoops)
  }

  @Test
  func theChoiceSurvivesARoundTrip() throws {
    var settings = GraphcodeSettings()
    settings.keepsMacAwakeWhileLoopsRun = true
    let decoded = try JSONDecoder().decode(
      GraphcodeSettings.self, from: JSONEncoder().encode(settings))
    #expect(decoded.keepsMacAwakeWhileLoopsRun)
  }

  /// Applying is idempotent: the registry states the current answer on every graph change
  /// rather than tracking edges, so holding while held and releasing while released both
  /// have to be no-ops.
  @Test
  func applyingTheSameAnswerTwiceIsANoOp() async {
    let assertion = AwakeAssertion()
    await assertion.apply(shouldHold: false, runningLoops: 0)
    #expect(!(await assertion.isHolding))
    await assertion.apply(shouldHold: true, runningLoops: 2)
    let held = await assertion.isHolding
    await assertion.apply(shouldHold: true, runningLoops: 3)
    #expect(await assertion.isHolding == held)
    await assertion.apply(shouldHold: false, runningLoops: 0)
    #expect(!(await assertion.isHolding))
  }

  /// Only `.running` counts. A loop parked on a human's answer is not work in flight, and
  /// holding a machine sleepless overnight for one is the opposite of the point.
  @Test
  func onlyRunningLoopsCount() async {
    let graph = LoopGraph(
      scope: LoopGraphScope(projectPath: "/tmp/p", name: "p"),
      nodes: [
        LoopNode(title: "a", state: .running),
        LoopNode(title: "b", state: .awaitingInput),
        LoopNode(title: "c", state: .idle),
        LoopNode(title: "d", state: .running),
        LoopNode(title: "e", state: .stopped),
      ])
    let store = GraphStore(graph: graph)
    #expect(await store.runningLoopCount() == 2)
  }
}
