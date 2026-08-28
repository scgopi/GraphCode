import Foundation
import Testing

@testable import GraphcodeKit

/// What `SessionTransplant.restoreRemote` sends to the host an imported loop will run
/// on. The local restore writes into this Mac's home directory, which a remote session
/// never reads — so a remote import used to arrive with its transcript left behind and
/// start fresh from the goal prompt. The remote install has to land two things on the
/// host, in order: the id-rewritten session files where the backend looks for them, and
/// the fresh id at the exact file the ensure's resume branch consumes
/// (`PresenceHooks.remoteSessionIDExpression`).
@Suite
struct RemoteSessionTransplantTests {
  private let location = RemoteProjectLocation(
    user: "dev", host: "codespace", remotePath: "/workspaces/widget")
  private let nodeID = UUID()

  private func artifact(
    _ backend: CLISessionBackendKind, files: [String: Data] = ["transcript.jsonl": Data("x".utf8)]
  ) -> SessionTransplant.Artifact {
    SessionTransplant.Artifact(
      backend: backend, sessionID: "aaaa-bbbb",
      sourceWorkingDirectory: "/Users/someone/src", files: files)
  }

  @Test
  func claudeInstallLandsInTheHostsOwnSlugDirectory() throws {
    let script = try #require(
      SessionTransplant.remoteInstallScript(
        for: artifact(.claudeCode), freshID: "fresh-id", nodeID: nodeID, at: location))

    // The slug is computed on the host from its own resolved path — `/tmp` is
    // `/private/tmp` on a Mac and itself on Linux, and only the host knows which.
    #expect(script.contains("cd '/workspaces/widget'"))
    #expect(script.contains("pwd -P"))
    #expect(script.contains("tr -c '[:alnum:]' '-'"))
    #expect(script.contains("$HOME/.claude/projects/$slug"))
    #expect(script.contains("tar -xf -"))
  }

  @Test
  func installBanksTheFreshIDWhereTheEnsureResumeBranchReads() throws {
    let script = try #require(
      SessionTransplant.remoteInstallScript(
        for: artifact(.claudeCode), freshID: "fresh-id", nodeID: nodeID, at: location))

    // Written last — `set -e` plus ordering means a failed transfer banks nothing and
    // the ensure falls through to today's fresh start.
    let bank = try #require(script.range(of: ".graphcode/sessions/\(nodeID.uuidString).id"))
    let untar = try #require(script.range(of: "tar -xf -"))
    #expect(script.hasPrefix("set -e;"))
    #expect(untar.lowerBound < bank.lowerBound)
    #expect(script.contains("printf %s 'fresh-id'"))
  }

  @Test
  func copilotInstallTargetsItsSessionStateDirectory() throws {
    let script = try #require(
      SessionTransplant.remoteInstallScript(
        for: artifact(.copilotCLI, files: ["state.json": Data("{}".utf8)]),
        freshID: "fresh-id", nodeID: nodeID, at: location))

    #expect(script.contains("$HOME/.copilot/session-state/fresh-id"))
    #expect(script.contains(".graphcode/sessions/\(nodeID.uuidString).id"))
  }

  @Test
  func backendsThatCannotResumeGetNoRemoteInstall() {
    #expect(
      SessionTransplant.remoteInstallScript(
        for: artifact(.codex), freshID: "f", nodeID: nodeID, at: location) == nil)
    #expect(
      SessionTransplant.remoteInstallScript(
        for: artifact(.openCode), freshID: "f", nodeID: nodeID, at: location) == nil)
  }

  @Test
  func bankPathMatchesWhatTheEnsureConsumes() throws {
    // The writer here and the reader in `remoteCreateScript` must name the same file;
    // drifting apart would not fail loudly — every remote import would just silently
    // start fresh, the exact bug this path exists to end.
    let script = try #require(
      SessionTransplant.remoteInstallScript(
        for: artifact(.claudeCode), freshID: "fresh-id", nodeID: nodeID, at: location))
    let consumed = PresenceHooks.remoteSessionIDExpression(forNodeID: nodeID)
      .replacingOccurrences(of: "\"", with: "")
    let written = try #require(
      script.split(separator: ";").last.map(String.init)?
        .split(separator: ">").last.map { $0.trimmingCharacters(in: .whitespaces) }
    ).replacingOccurrences(of: "\"", with: "")
    #expect(written == consumed)
  }
}
