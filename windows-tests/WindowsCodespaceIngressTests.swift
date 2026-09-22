import Foundation
import XCTest

@testable import GraphcodeKit

/// The daemon half of Windows codespace ingress. The Windows shell builds a
/// `codespace://` project path and hands it to `openProject`; everything below the
/// protocol has to already understand that path and be able to find `gh.exe` without
/// a `PATH` search, or the project opens and every session in it fails to dial.
final class WindowsCodespaceIngressTests: XCTestCase {
  func testCodespaceProjectPathRoundTripsThroughTheDaemonsParser() throws {
    let projectPath = "codespace://fluffy-space-giggle-abc123/workspaces/widget"
    let location = try XCTUnwrap(RemoteProjectLocation.parse(projectPath: projectPath))

    XCTAssertTrue(location.isCodespace)
    XCTAssertEqual(location.host, "fluffy-space-giggle-abc123")
    XCTAssertEqual(location.remotePath, "/workspaces/widget")
    XCTAssertEqual(location.projectPath, projectPath)
  }

  func testCodespacePathsWithSpacesSurviveTheEncoding() throws {
    let location = RemoteProjectLocation(
      host: "curly-halibut-9f8f8",
      remotePath: "/workspaces/my project",
      isCodespace: true
    )
    let reparsed = try XCTUnwrap(RemoteProjectLocation.parse(projectPath: location.projectPath))
    XCTAssertEqual(reparsed.remotePath, "/workspaces/my project")
    XCTAssertTrue(reparsed.isCodespace)
  }

  func testCodespaceInvocationDialsThroughTheGitHubCLIRatherThanSSH() {
    let location = RemoteProjectLocation(
      host: "curly-halibut-9f8f8",
      remotePath: "/workspaces/widget",
      isCodespace: true
    )
    let invocation = location.sshInvocation(remoteCommand: "echo ready")

    XCTAssertEqual(invocation.first, GhLocator.executablePath)
    XCTAssertEqual(Array(invocation.dropFirst().prefix(4)), [
      "codespace", "ssh", "-c", "curly-halibut-9f8f8",
    ])
    XCTAssertTrue(invocation.contains("--"))
  }

  func testGhLocatorNamesAnAbsolutePathOnEveryPlatform() {
    let path = GhLocator.executablePath
    XCTAssertFalse(path.isEmpty)
    #if os(Windows)
      // `Process` never searches `PATH`, so a bare `gh.exe` would fail to exec; and
      // the fallback has to be a real install location so the error names somewhere
      // worth installing to.
      XCTAssertTrue(path.lowercased().hasSuffix("gh.exe"), path)
      XCTAssertTrue(path.contains(":\\"), path)
      XCTAssertTrue(GhLocator.candidates.count >= 2)
    #else
      XCTAssertTrue(path.hasPrefix("/"), path)
    #endif
  }
}
