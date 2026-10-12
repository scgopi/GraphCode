import Foundation
import XCTest

@testable import GraphcodeKit

/// A writer killed between Foundation's temp-file create and its rename leaves
/// `.dat.nosync<pid>.<random>` beside the graph. These run against a scratch support
/// directory only.
final class AbandonedTempFileTests: XCTestCase {
  private var base: URL!
  private var projects: URL { base.appendingPathComponent("projects", isDirectory: true) }

  override func setUpWithError() throws {
    base = FileManager.default.temporaryDirectory
      .appendingPathComponent("graphcode-tempsweep-\(UUID().uuidString)", isDirectory: true)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: base)
  }

  private func plant(_ name: String, age: TimeInterval, body: String = "{}") throws -> URL {
    let url = projects.appendingPathComponent(name)
    try Data(body.utf8).write(to: url)
    try FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
    return url
  }

  private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

  func testOnlyExactTempPatternIsRecognised() {
    XCTAssertEqual(ProjectPersistence.atomicWriteTempFileOwner(".dat.nosync8040.a30616"), 0x8040)
    XCTAssertEqual(ProjectPersistence.atomicWriteTempFileOwner(".dat.nosync1F.AbC123"), 0x1F)
    for name in [
      "v1-abc.json", "v1-abc.json.bak", ".dat.nosync.a30616", ".dat.nosync8040.a3061",
      ".dat.nosync8040.a306166", ".dat.nosync8040.a30616.json", ".dat.nosyncZZ.a30616",
      "x.dat.nosync8040.a30616", ".dat.nosync8040", ".dat.nosync8040.a3061!",
      ".dat.nosyncdead.a1b2c3", ".dat.nosync1f.a1b2c3", ".dat.nosyncDeAD.a1b2c3",
    ] {
      XCTAssertNil(ProjectPersistence.atomicWriteTempFileOwner(name), name)
    }
  }

  func testDeadOwnerLeftoversAreRemovedAndEverythingElseSurvives() throws {
    let persistence = ProjectPersistence(baseDirectory: base)
    let project = ProjectRef(path: "C:\\synthetic\\Core", name: "Core")
    persistence.saveGraph(
      LoopGraph(project: project, nodes: [LoopNode(title: "Real", loopType: .turnBased)]))
    let realName = try XCTUnwrap(
      FileManager.default.contentsOfDirectory(atPath: projects.path).first {
        $0.hasSuffix(".json")
      })
    let realBefore = try Data(contentsOf: projects.appendingPathComponent(realName))

    let stale1 = try plant(".dat.nosync8040.a30616", age: 3600, body: "{\"torn\":")
    let stale2 = try plant(".dat.nosync8040.a35080", age: 3600)
    let live = try plant(".dat.nosync9000.a11111", age: 3600)
    let young = try plant(".dat.nosync9000.a22222", age: 1)
    let fresh = try plant(".dat.nosync8040.a33333", age: 0)
    let lookalike = try plant(".dat.nosync8040.a30616.json", age: 3600)
    let unrelated = try plant("notes.txt", age: 3600)
    let backup = try plant("v1-deadbeef.json.bak", age: 3600)

    let removed = persistence.sweepAbandonedTempFiles { $0 == 0x9000 ? .alive : .dead }

    XCTAssertEqual(
      Set(removed), [stale1.lastPathComponent, stale2.lastPathComponent, fresh.lastPathComponent])
    XCTAssertFalse(exists(stale1))
    XCTAssertFalse(exists(stale2))
    XCTAssertFalse(exists(fresh), "a just-killed writer's fresh leftover goes too")
    for kept in [live, young, lookalike, unrelated, backup] {
      XCTAssertTrue(exists(kept), kept.lastPathComponent)
    }
    XCTAssertEqual(try Data(contentsOf: projects.appendingPathComponent(realName)), realBefore)
    XCTAssertEqual(persistence.loadGraph(path: project.path)?.nodes.count, 1)
  }

  func testLiveOrUnknownOwnersTempIsKeptHoweverOld() throws {
    let persistence = ProjectPersistence(baseDirectory: base)
    let alive = try plant(".dat.nosync9000.a11111", age: 3 * 24 * 3600)
    let unknown = try plant(".dat.nosyncA000.a22222", age: 3 * 24 * 3600)

    persistence.sweepAbandonedTempFiles { $0 == 0x9000 ? .alive : .unknown }

    XCTAssertTrue(exists(alive))
    XCTAssertTrue(exists(unknown), "access denied / failed query must keep the file")
  }

  func testManyLiveCandidatesDoNotStarveALaterDeadOne() throws {
    let persistence = ProjectPersistence(baseDirectory: base)
    for index in 0..<300 { _ = try plant(".dat.nosync9000.b\(String(format: "%05d", index))", age: 1) }
    let dead = try plant(".dat.nosync8040.a30616", age: 0)

    persistence.sweepAbandonedTempFiles { $0 == 0x9000 ? .alive : .dead }

    XCTAssertFalse(exists(dead))
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: projects.path).count, 300)
  }

  func testDirectoryNamedLikeATempFileIsNotDeleted() throws {
    let persistence = ProjectPersistence(baseDirectory: base)
    let dir = projects.appendingPathComponent(".dat.nosync8040.a30616", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    persistence.sweepAbandonedTempFiles { _ in .dead }

    XCTAssertTrue(exists(dir))
  }

  func testMatchingNameSymlinkAndItsTargetArePreserved() throws {
    let persistence = ProjectPersistence(baseDirectory: base)
    let target = try plant("target.txt", age: 3600)
    let link = projects.appendingPathComponent(".dat.nosync8040.a30616")
    do {
      try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    } catch {
      throw XCTSkip("symlink creation unavailable: \(error)")
    }

    persistence.sweepAbandonedTempFiles { _ in .dead }

    XCTAssertTrue(exists(target))
    XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path))
  }

  func testLoadNeverReadsATempFileAsAGraph() throws {
    let persistence = ProjectPersistence(baseDirectory: base)
    let project = ProjectRef(path: "C:\\synthetic\\Core", name: "Core")
    persistence.saveGraph(LoopGraph(project: project, nodes: []))
    let newerComplete = LoopGraph(
      project: project,
      nodes: [LoopNode(title: "Unacknowledged", loopType: .turnBased)])
    _ = try plant(
      ".dat.nosync8040.a30616", age: 0,
      body: String(decoding: try JSONEncoder().encode(newerComplete), as: UTF8.self))

    XCTAssertEqual(persistence.loadGraph(path: project.path)?.nodes.count, 0)
  }

  func testDefaultLivenessSeesARealKilledProcessAsDeadAndThisProcessAsLive() throws {
    let child = Process()
    #if os(Windows)
      child.executableURL = URL(fileURLWithPath: "C:\\Windows\\System32\\cmd.exe")
      child.arguments = ["/c", "ping -n 30 127.0.0.1 >nul"]
    #else
      child.executableURL = URL(fileURLWithPath: "/bin/sleep")
      child.arguments = ["30"]
    #endif
    try child.run()
    let childPID = child.processIdentifier
    child.terminate()
    child.waitUntilExit()

    let persistence = ProjectPersistence(baseDirectory: base)
    let hex = { (pid: Int32) in String(UInt32(bitPattern: pid), radix: 16, uppercase: true) }
    let dead = try plant(".dat.nosync\(hex(childPID)).a30616", age: 3600)
    let mine = try plant(
      ".dat.nosync\(hex(ProcessInfo.processInfo.processIdentifier)).a30617", age: 3600)

    persistence.sweepAbandonedTempFiles()

    XCTAssertFalse(exists(dead))
    XCTAssertTrue(exists(mine))
  }

  #if os(Windows)
    func testRegistryStartupSweepsDeadOwnerAndKeepsLiveOwner() throws {
      let child = Process()
      child.executableURL = URL(fileURLWithPath: "C:\\Windows\\System32\\cmd.exe")
      child.arguments = ["/c", "ping -n 30 127.0.0.1 >nul"]
      try child.run()
      let childPID = child.processIdentifier
      child.terminate()
      child.waitUntilExit()
      try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
      let hex = { (pid: Int32) in String(UInt32(bitPattern: pid), radix: 16, uppercase: true) }
      let dead = try plant(".dat.nosync\(hex(childPID)).a30616", age: 0)
      let live = try plant(
        ".dat.nosync\(hex(ProcessInfo.processInfo.processIdentifier)).a30617", age: 0)

      _ = ProjectRegistry(persistenceDirectory: base)

      XCTAssertFalse(exists(dead))
      XCTAssertTrue(exists(live))
    }
  #endif
}
