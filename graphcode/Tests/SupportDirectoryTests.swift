import Foundation
import Testing

@testable import GraphcodeKit

/// Where graphcode keeps its own state, and the one-time move from the old location.
///
/// The migration is the part worth testing hardest: it moves a directory containing every
/// project's graph, and getting it wrong means someone opens the app to find their loops
/// gone. So the tests are mostly about what it refuses to do.
///
/// **Nothing here touches the real `~/.graphcode`.** Every migration test injects a pair
/// of temporary directories, which is why `prepare(destination:legacy:)` takes them at
/// all — an earlier version of this suite called the production entry point and moved the
/// developer's actual support directory out from under a running daemon.
@Suite
struct SupportDirectoryTests {
  @Test
  func everythingHangsOffOneDirectory() {
    // The point of the type: three call sites used to each rebuild this path by hand.
    let root = SupportDirectory.url

    #expect(root.lastPathComponent == ".graphcode")
    #expect(DaemonSocketPath.url.deletingLastPathComponent() == root)
    #expect(ZmxLocator.binaryURL.deletingLastPathComponent() == SupportDirectory.binDirectory)
    #expect(SupportDirectory.binDirectory.deletingLastPathComponent() == root)
  }

  @Test
  func theSocketPathFitsInSunPathWithRoomToSpare() {
    // `sockaddr_un.sun_path` is a hard 104 bytes on Darwin, and a bind that overflows it
    // fails at runtime rather than at compile time — which is exactly the kind of thing
    // that only shows up on someone else's machine, with a longer username.
    #expect(DaemonSocketPath.url.path.utf8.count < 104)

    // The home directory is the variable part; the fixed remainder has to stay small
    // enough that even an unusually long one still fits.
    let afterHome = DaemonSocketPath.url.path.replacingOccurrences(
      of: NSHomeDirectory(), with: "")
    #expect(afterHome.utf8.count < 40)
  }

  // MARK: - Migration

  /// A scratch pair of paths — neither created — plus cleanup.
  private func withScratchPaths(_ body: (_ legacy: URL, _ destination: URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("graphcode-support-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(
      root.appendingPathComponent("legacy", isDirectory: true),
      root.appendingPathComponent(".graphcode", isDirectory: true))
  }

  private func makeDirectory(_ url: URL, containing file: String? = nil) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    if let file {
      try Data(#"{"marker":true}"#.utf8).write(to: url.appendingPathComponent(file))
    }
  }

  @Test
  func anOldInstallIsMovedAcrossWithItsContents() throws {
    try withScratchPaths { legacy, destination in
      try makeDirectory(legacy.appendingPathComponent("projects"), containing: "graph.json")

      #expect(SupportDirectory.migrateIfNeeded(from: legacy, to: destination))

      let moved = destination.appendingPathComponent("projects/graph.json")
      #expect(FileManager.default.fileExists(atPath: moved.path))
      // A move, not a copy: two live copies — a daemon writing one, a human reading the
      // other — is a worse failure than either location alone.
      #expect(!FileManager.default.fileExists(atPath: legacy.path))
    }
  }

  @Test
  func aFreshInstallHasNothingToMigrate() throws {
    try withScratchPaths { legacy, destination in
      #expect(!SupportDirectory.migrateIfNeeded(from: legacy, to: destination))
      #expect(!FileManager.default.fileExists(atPath: destination.path))
    }
  }

  @Test
  func anExistingNewDirectoryIsNeverMergedInto() throws {
    // The case that would lose data. A merge has to decide which copy of a project's
    // graph wins, and guessing wrong silently discards someone's loops — so it refuses
    // and leaves both alone for a human to sort out.
    try withScratchPaths { legacy, destination in
      try makeDirectory(legacy.appendingPathComponent("projects"), containing: "old.json")
      try makeDirectory(destination.appendingPathComponent("projects"), containing: "new.json")

      #expect(!SupportDirectory.migrateIfNeeded(from: legacy, to: destination))

      // Both survive, untouched.
      #expect(
        FileManager.default.fileExists(
          atPath: legacy.appendingPathComponent("projects/old.json").path))
      #expect(
        FileManager.default.fileExists(
          atPath: destination.appendingPathComponent("projects/new.json").path))
    }
  }

  @Test
  func prepareIsIdempotent() throws {
    // Both the app and the daemon call it, on every launch, in either order.
    try withScratchPaths { legacy, destination in
      try makeDirectory(legacy, containing: "graph.json")

      SupportDirectory.prepare(destination: destination, legacy: legacy)
      SupportDirectory.prepare(destination: destination, legacy: legacy)
      SupportDirectory.prepare(destination: destination, legacy: legacy)

      #expect(
        FileManager.default.fileExists(
          atPath: destination.appendingPathComponent("graph.json").path))
    }
  }

  @Test
  func prepareCreatesTheDirectoryEvenWithNothingToMigrate() throws {
    try withScratchPaths { legacy, destination in
      SupportDirectory.prepare(destination: destination, legacy: legacy)

      var isDirectory: ObjCBool = false
      let exists = FileManager.default.fileExists(
        atPath: destination.path, isDirectory: &isDirectory)
      #expect(exists)
      #expect(isDirectory.boolValue)
    }
  }
}
