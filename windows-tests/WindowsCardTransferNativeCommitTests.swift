import Foundation
import WinSDK
import XCTest

@testable import WindowsCardTransferCore

final class WindowsCardTransferNativeCommitTests: XCTestCase {
  private struct Fixture {
    let root: URL
    let staging: URL
    let source: URL
    let target: URL
    let parent: HANDLE
    let archive: HANDLE
    let bytes = Data([0x50, 0x4B, 3, 4, 1, 2, 3])
  }

  private func wide<T>(_ url: URL, _ body: (UnsafePointer<WCHAR>) throws -> T) rethrows -> T {
    try (Array(url.path.replacingOccurrences(of: "/", with: "\\").utf16) + [0])
      .withUnsafeBufferPointer { try body($0.baseAddress!) }
  }

  private func open(_ url: URL, access: DWORD, share: DWORD, directory: Bool) throws -> HANDLE {
    let handle = wide(url) {
      CreateFileW(
        $0, access, share, nil, DWORD(OPEN_EXISTING),
        DWORD(FILE_FLAG_OPEN_REPARSE_POINT | (directory ? FILE_FLAG_BACKUP_SEMANTICS : 0)), nil)
    }
    return try XCTUnwrap(handle != INVALID_HANDLE_VALUE ? handle : nil, "Native fixture open: \(GetLastError())")
  }

  private func withFixture(_ body: (Fixture) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "graphcode-native-commit \(UUID().uuidString)", isDirectory: true)
    let staging = root.appendingPathComponent("staging", isDirectory: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    defer {
      do { try FileManager.default.removeItem(at: root) }
      catch { XCTFail("Owned native fixture cleanup failed: \(error)") }
    }
    let source = staging.appendingPathComponent("bundle.zip")
    let bytes = Data([0x50, 0x4B, 3, 4, 1, 2, 3])
    try bytes.write(to: source, options: .withoutOverwriting)
    let sentinel = root.appendingPathComponent("sentinel")
    let sentinelBytes = Data("untouched owned sentinel".utf8)
    try sentinelBytes.write(to: sentinel, options: .withoutOverwriting)
    let parent = try open(
      root, access: DWORD(FILE_LIST_DIRECTORY | FILE_ADD_FILE | FILE_READ_ATTRIBUTES),
      share: DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE), directory: true)
    defer { XCTAssertTrue(CloseHandle(parent)) }
    let directory = try open(
      staging, access: DWORD(DELETE | FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES),
      share: DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE), directory: true)
    defer { XCTAssertTrue(CloseHandle(directory)) }
    let archive = try open(
      source, access: DWORD(DELETE | FILE_READ_DATA | FILE_READ_ATTRIBUTES),
      share: DWORD(FILE_SHARE_READ), directory: false)
    defer { XCTAssertTrue(CloseHandle(archive)) }
    try body(
      Fixture(
        root: root, staging: staging, source: source,
        target: root.appendingPathComponent("bundle \u{96EA}.zip"), parent: parent, archive: archive))
    XCTAssertEqual(try Data(contentsOf: sentinel), sentinelBytes)
  }

  private func commit(_ fixture: Fixture, replace: Bool = false) throws {
    try CardTransferNativeArchiveCommit.rename(
      archive: fixture.archive, parent: fixture.parent,
      filename: fixture.target.lastPathComponent, replaceExisting: replace)
  }

  func testAbsentDestinationCommitsExactHeldSourceIntoHeldParent() throws {
    try withFixture { fixture in
      try commit(fixture)
      XCTAssertEqual(try Data(contentsOf: fixture.target), fixture.bytes)
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.source.path))
      XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.staging.path), [])
    }
  }

  func testDestinationCreatedAfterPreparationIsNotClobberedWithoutApproval() throws {
    try withFixture { fixture in
      let existing = Data("existing destination must survive".utf8)
      try existing.write(to: fixture.target, options: .withoutOverwriting)
      XCTAssertThrowsError(try commit(fixture)) { error in
        XCTAssertEqual((error as? CardTransferFailure)?.status, .outcome_unknown)
      }
      XCTAssertEqual(try Data(contentsOf: fixture.target), existing)
      XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.bytes)
    }
  }

  func testExplicitReplacementCommitsWithOriginalHeldDirectoryAuthority() throws {
    try withFixture { fixture in
      try Data("explicitly approved old bytes".utf8).write(to: fixture.target, options: .withoutOverwriting)
      try commit(fixture, replace: true)
      XCTAssertEqual(try Data(contentsOf: fixture.target), fixture.bytes)
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.source.path))
    }
  }

  func testHeldParentAndSourceCannotBeRenamedBeforeCommit() throws {
    try withFixture { fixture in
      let alternate = fixture.root.appendingPathComponent("not-the-source.zip")
      let sourceMoved = wide(fixture.source) { source in wide(alternate) { MoveFileExW(source, $0, 0) } }
      let sourceError = GetLastError()
      XCTAssertFalse(sourceMoved)
      XCTAssertEqual(sourceError, DWORD(ERROR_SHARING_VIOLATION))
      let alternateParent = fixture.root.appendingPathExtension("renamed")
      let parentMoved = wide(fixture.root) { parent in wide(alternateParent) { MoveFileExW(parent, $0, 0) } }
      let parentError = GetLastError()
      XCTAssertFalse(parentMoved)
      XCTAssertEqual(parentError, DWORD(ERROR_SHARING_VIOLATION))
      try commit(fixture)
      XCTAssertEqual(try Data(contentsOf: fixture.target), fixture.bytes)
      XCTAssertFalse(FileManager.default.fileExists(atPath: alternateParent.path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: alternate.path))
    }
  }

  func testRelativeAndAbsoluteEscapeNamesAreRefusedBeforeNativeDispatch() throws {
    try withFixture { fixture in
      for filename in ["", ".", "..", "..\\escape.zip", "sub/file.zip", "D:\\elsewhere.zip", "bad\0name.zip"] {
        XCTAssertThrowsError(
          try CardTransferNativeArchiveCommit.rename(
            archive: fixture.archive, parent: fixture.parent, filename: filename, replaceExisting: false)
        ) { error in
          XCTAssertEqual((error as? CardTransferFailure)?.status, .rejected)
        }

      }
      XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.bytes)
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.target.path))
    }
  }

  func testApprovedReplacementCannotBypassHeldDestinationCustody() throws {
    try withFixture { fixture in
      let existing = Data("held destination remains authoritative".utf8)
      try existing.write(to: fixture.target, options: .withoutOverwriting)
      let target = try open(
        fixture.target, access: DWORD(FILE_READ_DATA | FILE_READ_ATTRIBUTES),
        share: DWORD(FILE_SHARE_READ), directory: false)
      defer { XCTAssertTrue(CloseHandle(target)) }
      XCTAssertThrowsError(try commit(fixture, replace: true)) { error in
        let failure = error as? CardTransferFailure
        XCTAssertEqual(failure?.status, .outcome_unknown)
        XCTAssertTrue(failure?.message.contains("NTSTATUS") == true)
      }
      XCTAssertEqual(try Data(contentsOf: fixture.target), existing)
      XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.bytes)
    }
  }

  func testPendingUnobservedAndFailedCompletionCannotReportSuccess() throws {
    try CardTransferNativeArchiveCommit.requireSynchronousSuccess(returned: 0, completed: 0)
    let collision = NTSTATUS(bitPattern: 0xC0000035)
    for (returned, completed) in [
      (NTSTATUS(0x103), NTSTATUS(0)), (NTSTATUS(0), NTSTATUS(0x103)),
      (collision, NTSTATUS(0)), (NTSTATUS(0), collision), (collision, collision),
    ] {
      XCTAssertThrowsError(
        try CardTransferNativeArchiveCommit.requireSynchronousSuccess(returned: returned, completed: completed)
      ) { error in
        let failure = error as? CardTransferFailure
        XCTAssertEqual(failure?.status, .outcome_unknown)
        XCTAssertTrue(failure?.message.contains(String(UInt32(bitPattern: returned), radix: 16)) == true)
        XCTAssertTrue(failure?.message.contains(String(UInt32(bitPattern: completed), radix: 16)) == true)
      }
    }
  }
}
