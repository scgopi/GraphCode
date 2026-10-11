import Foundation
import XCTest

@testable import GraphcodeKit

final class ReadProjectGraphTests: XCTestCase {
  private func fixtureRegistry(at root: URL) -> ProjectRegistry {
    ProjectRegistry(
      persistenceDirectory: root.appendingPathComponent("persistence"),
      ensureSession: nil, restoreRebootedSessions: nil, terminateSession: nil,
      restartSession: nil, evaluatePredicate: nil, checkPredicate: nil,
      deliverMessage: nil, captureScript: nil, readUsage: nil, readGoalVerdict: nil,
      readActivity: nil, readSummary: nil, readPresence: nil, sessionAlive: nil,
      composeBoard: nil,
      startQuickChat: { _, _ in .failure(.unavailable("test fixture")) },
      terminateQuickChat: { _, _ in .failure(.unavailable("test fixture")) },
      quickChatExists: { _, _ in false }, enumerateQuickChatSessions: { [] })
  }

  private func scratch() throws -> (root: URL, folder: URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "graphcode-readgraph-\(UUID().uuidString)", isDirectory: true)
    let folder = root.appendingPathComponent("project", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return (root, folder)
  }

  /// Every persisted file under the registry's persistence directory, by relative path.
  private func persistedState(_ root: URL) -> [String: Data] {
    var state: [String: Data] = [:]
    let base = root.appendingPathComponent("persistence")
    guard
      let walker = FileManager.default.enumerator(
        at: base, includingPropertiesForKeys: [.isRegularFileKey])
    else { return state }
    for case let url as URL in walker {
      guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
      else { continue }
      state[String(url.path.dropFirst(base.path.count))] = try? Data(contentsOf: url)
    }
    return state
  }

  func testJoinedProjectAnswersWithOneResponseAndNoExtraFrameOrMutation() async throws {
    let (root, folder) = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let registry = fixtureRegistry(at: root)
    let channel = ReadGraphMemoryConnection()
    await registry.addConnection(id: channel.id, connection: channel, mode: .v2(version: 2))
    let path = ProjectRegistry.canonicalize(folder.path)
    guard
      case .graphChanged(let opened)? = await registry.apply(
        .openProject(path: path), connectionID: channel.id)?.response
    else { return XCTFail("Could not open fixture project") }
    registry.flushPersistence()
    let framesBefore = await channel.frames
    let stateBefore = persistedState(root)
    XCTAssertFalse(stateBefore.isEmpty, "Open must have persisted something to compare against")

    let result = await registry.apply(.readProjectGraph(path: path), connectionID: channel.id)
    guard case .graphChanged(let read)? = result?.response else {
      return XCTFail("Expected one graphChanged response, got \(String(describing: result))")
    }
    XCTAssertNil(result?.error)
    XCTAssertEqual(read.id, opened.id)
    XCTAssertEqual(read.nodes, opened.nodes)
    let framesAfter = await channel.frames
    XCTAssertEqual(framesAfter, framesBefore, "Read must not emit an uncorrelated event")

    registry.flushPersistence()
    XCTAssertEqual(persistedState(root), stateBefore, "Read must not touch persisted state")
    let again = await registry.apply(.readProjectGraph(path: path), connectionID: channel.id)
    XCTAssertNotNil(again?.response)
    let framesTwice = await channel.frames
    XCTAssertEqual(framesTwice, framesBefore)
    await registry.removeConnection(channel.id)
    registry.flushPersistence()
  }

  func testNeverOpenedProjectIsRefusedAndNotOpened() async throws {
    let (root, folder) = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let registry = fixtureRegistry(at: root)
    let channel = ReadGraphMemoryConnection()
    await registry.addConnection(id: channel.id, connection: channel, mode: .v2(version: 2))
    let path = ProjectRegistry.canonicalize(folder.path)
    let result = await registry.apply(.readProjectGraph(path: path), connectionID: channel.id)
    XCTAssertNil(result?.response)
    XCTAssertNotNil(result?.error)
    XCTAssertFalse(result?.succeeded ?? true)
    registry.flushPersistence()
    XCTAssertTrue(persistedState(root).isEmpty, "A refused read must persist nothing")
    let frames = await channel.frames
    XCTAssertEqual(frames, 0)
    // A later read still refuses: the first one did not open the project.
    let second = await registry.apply(.readProjectGraph(path: path), connectionID: channel.id)
    XCTAssertNotNil(second?.error)
    await registry.removeConnection(channel.id)
  }

  func testProjectClosedByThisOrAnotherConnectionIsNotReopened() async throws {
    let (root, folder) = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let registry = fixtureRegistry(at: root)
    let owner = ReadGraphMemoryConnection()
    let other = ReadGraphMemoryConnection()
    await registry.addConnection(id: owner.id, connection: owner, mode: .v2(version: 2))
    await registry.addConnection(id: other.id, connection: other, mode: .v2(version: 2))
    let path = ProjectRegistry.canonicalize(folder.path)
    _ = await registry.apply(.openProject(path: path), connectionID: owner.id)
    // Joined by `owner` only: `other` has no right to read it and must not join it.
    let foreign = await registry.apply(.readProjectGraph(path: path), connectionID: other.id)
    XCTAssertNotNil(foreign?.error)
    XCTAssertNil(foreign?.response)
    _ = await registry.apply(.closeProject(path: path), connectionID: owner.id)
    registry.flushPersistence()
    let closedState = persistedState(root)
    let framesBefore = await owner.frames
    let afterClose = await registry.apply(.readProjectGraph(path: path), connectionID: owner.id)
    XCTAssertNotNil(afterClose?.error)
    XCTAssertNil(afterClose?.response)
    registry.flushPersistence()
    XCTAssertEqual(persistedState(root), closedState, "Read after close must not reopen")
    let framesAfter = await owner.frames
    XCTAssertEqual(framesAfter, framesBefore)
    await registry.removeConnection(owner.id)
    await registry.removeConnection(other.id)
  }

  func testNonCanonicalAndNestedPathsAreRefusedWithoutRedirect() async throws {
    let (root, folder) = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let registry = fixtureRegistry(at: root)
    let channel = ReadGraphMemoryConnection()
    await registry.addConnection(id: channel.id, connection: channel, mode: .v2(version: 2))
    let path = ProjectRegistry.canonicalize(folder.path)
    _ = await registry.apply(.openProject(path: path), connectionID: channel.id)
    // Spellings of the same folder (case, separators, dot segments) are not the canonical key.
    let aliases = [
      path.uppercased(), path.lowercased(), path.replacingOccurrences(of: "/", with: "\\"),
      path + "/", path + "/.", path + "/../" + URL(fileURLWithPath: path).lastPathComponent,
    ]
    for bad in [path + "\\child", path + "\\", ""] + aliases where bad != path {
      let result = await registry.apply(.readProjectGraph(path: bad), connectionID: channel.id)
      XCTAssertNotNil(result?.error, "\(bad) should be refused")
      XCTAssertNil(result?.response, "\(bad) should not answer")
    }
    await registry.removeConnection(channel.id)
    registry.flushPersistence()
  }

  func testJoinedGlobalAndRemoteGraphsAreRefusedWithoutAnyFrameOrMutation() async throws {
    let (root, folder) = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let registry = fixtureRegistry(at: root)
    let channel = ReadGraphMemoryConnection()
    await registry.addConnection(id: channel.id, connection: channel, mode: .v2(version: 2))
    let local = ProjectRegistry.canonicalize(folder.path)
    let remote = ProjectRegistry.canonicalize("ssh://host/repository")
    guard
      case .graphChanged? = await registry.apply(.openGlobalGraph, connectionID: channel.id)?.response,
      case .graphChanged(let remoteGraph)? = await registry.apply(
        .openProject(path: remote), connectionID: channel.id)?.response
    else { return XCTFail("Could not join the global and remote graphs") }
    XCTAssertEqual(remoteGraph.project.path, remote)
    _ = await registry.apply(.openProject(path: local), connectionID: channel.id)
    registry.flushPersistence()
    let stateBefore = persistedState(root)
    let framesBefore = await channel.frames

    // Both are joined by this very connection, so only the explicit refusal stands in the way.
    for path in [LoopGraphScope.globalPath, remote] {
      let result = await registry.apply(.readProjectGraph(path: path), connectionID: channel.id)
      XCTAssertNotNil(result?.error, "\(path) should be refused")
      XCTAssertNil(result?.response, "\(path) should not answer")
    }
    registry.flushPersistence()
    XCTAssertEqual(persistedState(root), stateBefore)
    let framesAfter = await channel.frames
    XCTAssertEqual(framesAfter, framesBefore)
    // The local project joined alongside them is still readable.
    let localRead = await registry.apply(.readProjectGraph(path: local), connectionID: channel.id)
    XCTAssertNotNil(localRead?.response)
    await registry.removeConnection(channel.id)
    registry.flushPersistence()
  }

  func testV1ConnectionIsRefused() async throws {
    let (root, folder) = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let registry = fixtureRegistry(at: root)
    let channel = ReadGraphMemoryConnection()
    await registry.addConnection(id: channel.id, connection: channel)
    let path = ProjectRegistry.canonicalize(folder.path)
    _ = await registry.apply(.openProject(path: path), connectionID: channel.id)
    let result = await registry.apply(.readProjectGraph(path: path), connectionID: channel.id)
    XCTAssertNotNil(result?.error)
    XCTAssertNil(result?.response)
    await registry.removeConnection(channel.id)
    registry.flushPersistence()
  }

  func testCommandRoundTripsThroughCodable() throws {
    let command = DaemonCommand.readProjectGraph(path: "C:\\synthetic\\read")
    let data = try JSONEncoder().encode(command)
    XCTAssertEqual(try JSONDecoder().decode(DaemonCommand.self, from: data), command)
    let text = String(decoding: data, as: UTF8.self)
    XCTAssertTrue(text.contains("readProjectGraph"), text)
    // What a daemon that predates the command does with it is covered on the wire by
    // Tools/windows/Tests/ReadProjectGraph.Wire.ps1 (an unknown command is answered with an error).
  }
}

private actor ReadGraphMemoryConnection: DaemonConnection {
  nonisolated let id = UUID()
  nonisolated let endpoint: DaemonEndpoint = .namedPipe("\\\\.\\pipe\\read-graph-in-memory")
  private(set) var frames = 0

  func receiveFrame() async throws -> Data { throw Closed.connection }
  func sendFrame(_ data: Data) async throws { frames += 1 }
  func close() async throws {}

  private enum Closed: Error { case connection }
}
