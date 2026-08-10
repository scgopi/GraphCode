import Foundation
import Testing

@testable import GraphcodeKit

/// What may become a project at all.
///
/// `ProjectRegistry` used to open whatever string it was handed. `canonicalize` runs the
/// path through `URL(fileURLWithPath:)`, which resolves a relative path against the
/// process's working directory and an empty one to that directory outright — and
/// `graphcoded` runs under launchd, whose working directory is `/`. So an empty path from
/// any client became the root directory, which exists, so it opened, persisted, and came
/// back every launch as a folder called "/". Paths that named nothing at all became
/// projects too, each with its own JSON under `~/.graphcode/projects`.
@Suite
struct ProjectPathValidationTests {
  @Test
  func theRootIsRefusedHoweverItIsSpelled() {
    // The empty path is the one that actually happened: `graphcode status "$UNSET"`.
    #expect(!ProjectRegistry.isWellFormedProjectPath(""))
    #expect(!ProjectRegistry.isWellFormedProjectPath("/"))
    #expect(!ProjectRegistry.isWellFormedProjectPath("//"))
    #expect(!ProjectRegistry.isWellFormedProjectPath("/.."))
    #expect(!ProjectRegistry.isWellFormedProjectPath("/tmp/.."))
    // A project is scanned by the sweeper and by git; pointed at the root that is the
    // whole disk, so this is refused even when someone means it.
    #expect(!ProjectRegistry.isOpenable("/"))
  }

  @Test
  func aRelativePathIsNotAProject() {
    // These are the ones `URL(fileURLWithPath:)` silently rebases onto the daemon's own
    // working directory, inventing an absolute path nobody named.
    #expect(!ProjectRegistry.isWellFormedProjectPath("relative/path"))
    #expect(!ProjectRegistry.isWellFormedProjectPath("."))
    #expect(!ProjectRegistry.isWellFormedProjectPath("~/projects/widget"))
  }

  @Test
  func aDirectoryThatIsNotThereIsNotOpened() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("project-validation-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(ProjectRegistry.isOpenable(root.path))

    let missing = root.appendingPathComponent("gone", isDirectory: true).path
    #expect(ProjectRegistry.isWellFormedProjectPath(missing))
    #expect(!ProjectRegistry.isOpenable(missing))

    // A file is a real path and still not a project.
    let file = root.appendingPathComponent("notes.txt")
    try "x".write(to: file, atomically: true, encoding: .utf8)
    #expect(!ProjectRegistry.isOpenable(file.path))
  }

  @Test
  func theTwoPathsThatAreNotDirectoriesStillOpen() {
    // The global graph names no directory, and a remote project's directory is on another
    // machine — neither can be answered by asking this filesystem.
    #expect(ProjectRegistry.isOpenable(LoopGraphScope.globalPath))
    #expect(ProjectRegistry.isOpenable("ssh://dev@build-box:22/home/dev/widget"))
  }

  /// Restoring re-checks the spelling and not the filesystem: these paths were openable
  /// when they were added, and this user's projects live on an external volume. Dropping
  /// them while it is unmounted would empty the sidebar, and they must come back with it.
  @Test
  func restoringToleratesAVolumeThatIsNotMountedButNotJunk() {
    #expect(ProjectRegistry.isWellFormedProjectPath("/Volumes/External/wd/widget"))
    #expect(!ProjectRegistry.isOpenable("/Volumes/External/wd/widget"))
    #expect(!ProjectRegistry.isWellFormedProjectPath(""))
  }
}
