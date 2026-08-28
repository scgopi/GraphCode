import Dependencies
import Foundation
import GraphcodeKit

/// One codespace as `gh codespace list` reports it — exactly the fields the picker
/// shows, decoded from gh's own `--json` output so there is no scraping to drift.
struct Codespace: Equatable, Identifiable, Sendable, Decodable {
  var name: String
  var displayName: String
  /// `owner/repo`.
  var repository: String
  /// gh's word: `Available`, `Shutdown`, `Starting`, … Shown as-is; a stopped
  /// codespace is still addable, because `gh codespace ssh` starts it on connect.
  var state: String

  var id: String { name }

  /// Where a codespace puts its clone by default. Prefill only — the form's path
  /// field stays editable for devcontainers that mount elsewhere.
  var defaultWorkspacePath: String {
    let leaf = repository.split(separator: "/").last.map(String.init) ?? repository
    return "/workspaces/\(leaf)"
  }
}

/// Everything the add-codespace flow asks of the GitHub CLI. All of it rides `gh`
/// rather than the API directly: gh owns auth (keychain), the codespace scope check —
/// whose error text carries its own fix (`gh auth refresh -h github.com -s codespace`)
/// — and, later, the SSH tunnel every session dial uses.
struct CodespaceClient: Sendable {
  struct Failure: Equatable, Error {
    var message: String
  }

  var list: @Sendable () async -> Result<[Codespace], Failure>
  /// The GitHub repositories (`owner/repo`) behind the given local project folders —
  /// what the sheet's "create one" links point at when there is no codespace yet.
  var githubRepositories: @Sendable (_ projectPaths: [String]) async -> [String]
}

extension CodespaceClient: DependencyKey {
  static let liveValue = CodespaceClient(
    list: {
      guard GhLocator.isInstalled else {
        return .failure(
          Failure(
            message: "The GitHub CLI isn't installed — codespaces are reached through it. "
              + "`brew install gh`, then `gh auth login`, and try again."))
      }
      let result = await run(
        GhLocator.executablePath,
        ["codespace", "list", "--json", "name,displayName,repository,state"])
      guard result.status == 0 else {
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failure(Failure(message: stderr.isEmpty ? "gh codespace list failed." : stderr))
      }
      do {
        let codespaces = try JSONDecoder().decode(
          [Codespace].self, from: Data(result.stdout.utf8))
        return .success(codespaces)
      } catch {
        return .failure(Failure(message: "Couldn't read gh's codespace list."))
      }
    },
    githubRepositories: { projectPaths in
      var repositories: [String] = []
      for path in projectPaths {
        let result = await run("/usr/bin/git", ["-C", path, "remote", "get-url", "origin"])
        guard result.status == 0,
          let repository = githubRepository(
            fromOriginURL: result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)),
          !repositories.contains(repository)
        else { continue }
        repositories.append(repository)
      }
      return repositories
    }
  )

  /// No network, no gh, no repos — the shapes the reducer tests care about are fed
  /// through `withDependencies` instead.
  static let testValue = CodespaceClient(
    list: { .success([]) },
    githubRepositories: { _ in [] }
  )

  /// `owner/repo` from any of the ways a GitHub origin is written — https, scp-ish
  /// `git@`, or `ssh://` — and `nil` for an origin that isn't github.com, which is a
  /// repository no codespace link can be made for, not an error.
  static func githubRepository(fromOriginURL origin: String) -> String? {
    var slug: Substring?
    if let range = origin.range(of: "github.com/") ?? origin.range(of: "github.com:") {
      slug = origin[range.upperBound...]
    }
    guard var slug else { return nil }
    if slug.hasSuffix(".git") { slug = slug.dropLast(4) }
    let parts = slug.split(separator: "/")
    guard parts.count == 2,
      parts.allSatisfy({ SafeArgument.isSafePathComponent(String($0)) })
    else { return nil }
    return parts.joined(separator: "/")
  }

  private static func run(
    _ executable: String, _ arguments: [String]
  ) async -> (status: Int32, stdout: String, stderr: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    // Handler wired before launch, exit awaited via the stream — the arrangement
    // every subprocess here uses (`waitUntilExit` stalls the cooperative pool), and
    // pipes drained concurrently so a full one can't wedge the exit.
    let (exited, exitContinuation) = AsyncStream<Int32>.makeStream()
    process.terminationHandler = { process in
      exitContinuation.yield(process.terminationStatus)
      exitContinuation.finish()
    }
    do {
      try process.run()
    } catch {
      return (-1, "", error.localizedDescription)
    }
    async let outputData = readToEnd(stdout)
    async let errorData = readToEnd(stderr)
    let output = String(data: await outputData, encoding: .utf8) ?? ""
    let errorOutput = String(data: await errorData, encoding: .utf8) ?? ""
    var status: Int32 = -1
    for await exitStatus in exited { status = exitStatus }
    return (status, output, errorOutput)
  }

  private static func readToEnd(_ pipe: Pipe) async -> Data {
    let handle = pipe.fileHandleForReading
    return await Task.detached { (try? handle.readToEnd()) ?? Data() }.value
  }
}

extension DependencyValues {
  var codespaceClient: CodespaceClient {
    get { self[CodespaceClient.self] }
    set { self[CodespaceClient.self] = newValue }
  }
}
