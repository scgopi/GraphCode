import Dependencies
import Foundation

/// Graphcode's own minimal git client — create/list/remove a worktree, nothing more.
/// A `LoopNode`'s `worktreeBinding` is the only thing that needs this; it is not a
/// general git porcelain layer. See docs/03-architecture.md and
/// docs/07-roadmap.md#phase-1--single-loop-manual-check.
struct GitClient: Sendable {
  var createWorktree:
    @Sendable (_ repositoryPath: String, _ worktreePath: String, _ branch: String) async throws ->
      WorktreeRef
  var listWorktrees: @Sendable (_ repositoryPath: String) async throws -> [WorktreeRef]
  var removeWorktree: @Sendable (_ worktree: WorktreeRef) async throws -> Void
}

enum GitClientError: Error, Equatable {
  case commandFailed(command: String, status: Int32, output: String)
}

extension GitClient: DependencyKey {
  static let liveValue = GitClient(
    createWorktree: { repositoryPath, worktreePath, branch in
      _ = try run("git", ["-C", repositoryPath, "worktree", "add", "-b", branch, worktreePath])
      return WorktreeRef(
        id: branch,
        repositoryPath: repositoryPath,
        worktreePath: worktreePath,
        branch: branch
      )
    },
    listWorktrees: { repositoryPath in
      let output = try run("git", ["-C", repositoryPath, "worktree", "list", "--porcelain"])
      return parseWorktreeList(output, repositoryPath: repositoryPath)
    },
    removeWorktree: { worktree in
      _ = try run(
        "git", ["-C", worktree.repositoryPath, "worktree", "remove", worktree.worktreePath])
    }
  )
}

extension DependencyValues {
  var gitClient: GitClient {
    get { self[GitClient.self] }
    set { self[GitClient.self] = newValue }
  }
}

/// Parses `git worktree list --porcelain` output. Each worktree is a blank-line
/// separated block starting with `worktree <path>`, followed by `branch
/// refs/heads/<name>` (bare/detached worktrees, which have no branch line, are
/// skipped — graphcode's worktree bindings are always on a named branch).
private func parseWorktreeList(_ output: String, repositoryPath: String) -> [WorktreeRef] {
  var refs: [WorktreeRef] = []
  var currentPath: String?
  var currentBranch: String?

  func flush() {
    if let path = currentPath, let branch = currentBranch {
      refs.append(
        WorktreeRef(id: branch, repositoryPath: repositoryPath, worktreePath: path, branch: branch))
    }
    currentPath = nil
    currentBranch = nil
  }

  for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
    if line.isEmpty {
      flush()
    } else if line.hasPrefix("worktree ") {
      currentPath = String(line.dropFirst("worktree ".count))
    } else if line.hasPrefix("branch refs/heads/") {
      currentBranch = String(line.dropFirst("branch refs/heads/".count))
    }
  }
  flush()
  return refs
}

@discardableResult
private func run(_ executable: String, _ arguments: [String]) throws -> String {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  process.arguments = [executable] + arguments

  let stdout = Pipe()
  let stderr = Pipe()
  process.standardOutput = stdout
  process.standardError = stderr

  try process.run()
  process.waitUntilExit()

  let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
  let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
  let output = String(data: outputData, encoding: .utf8) ?? ""
  let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

  guard process.terminationStatus == 0 else {
    throw GitClientError.commandFailed(
      command: (["git"] + arguments).joined(separator: " "),
      status: process.terminationStatus,
      output: errorOutput.isEmpty ? output : errorOutput
    )
  }
  return output
}
