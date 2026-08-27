import Foundation
import Testing

@testable import GraphcodeKit

/// What lets `graphcoded` notice its binary was swapped underneath it (#199). The
/// discriminating case is the one `DaemonBootstrap` actually produces: a staged copy
/// renamed over the target, which is a fresh inode even when the bytes match.
@Suite
struct ExecutableIdentityTests {
  private func temporaryFile(containing text: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("identity-\(UUID().uuidString)")
    try Data(text.utf8).write(to: url)
    return url
  }

  @Test
  func theSameFileReadsTheSameTwice() throws {
    let url = try temporaryFile(containing: "binary bytes")
    let first = try #require(ExecutableIdentity.of(path: url.path))
    let second = try #require(ExecutableIdentity.of(path: url.path))
    #expect(first == second)
  }

  @Test
  func aStagedRenameIsADifferentFileEvenWithTheSameBytes() throws {
    let url = try temporaryFile(containing: "binary bytes")
    let before = try #require(ExecutableIdentity.of(path: url.path))
    let staged = try temporaryFile(containing: "binary bytes")
    try FileManager.default.removeItem(at: url)
    try FileManager.default.moveItem(at: staged, to: url)
    let after = try #require(ExecutableIdentity.of(path: url.path))
    #expect(before != after)
  }

  @Test
  func anUnreadablePathIsNilNotAnAnswer() {
    #expect(ExecutableIdentity.of(path: "/nonexistent/graphcoded") == nil)
  }
}

/// The sibling-workspace half of #199: helpers can be installed into any workspace's
/// bin, not only the current one's — what lets an update reach a workspace whose
/// window nobody has opened.
@Suite
struct SiblingHelperInstallTests {
  @Test
  func helpersLandInTheNamedDestination() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("sibling-\(UUID().uuidString)", isDirectory: true)
    let bundled = root.appendingPathComponent("bundled", isDirectory: true)
    try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
    for name in ["graphcoded", "zmx", "graphcode"] {
      FileManager.default.createFile(
        atPath: bundled.appendingPathComponent(name).path, contents: Data(name.utf8),
        attributes: [.posixPermissions: 0o755])
    }
    let destination = root.appendingPathComponent("workspace/bin", isDirectory: true)
    try DaemonBootstrap.installHelpers(from: bundled, to: destination)
    #expect(DaemonBootstrap.helpersInstalled(in: destination))
  }
}
