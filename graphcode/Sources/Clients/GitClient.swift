import Dependencies
import Foundation
import GraphcodeKit
import os

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
      _ = try await run(
        "git", ["-C", repositoryPath, "worktree", "add", "-b", branch, worktreePath])
      return WorktreeRef(
        id: branch,
        repositoryPath: repositoryPath,
        worktreePath: worktreePath,
        branch: branch
      )
    },
    listWorktrees: { repositoryPath in
      let output = try await run("git", ["-C", repositoryPath, "worktree", "list", "--porcelain"])
      return parseWorktreeList(output, repositoryPath: repositoryPath)
    },
    removeWorktree: { worktree in
      _ = try await run(
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

/// Runs a command and returns its standard output.
///
/// **Both pipes are drained before the process is waited on, and concurrently with each
/// other.** The order matters and the previous order deadlocked: `waitUntilExit()` came
/// first, and a child that writes more than the pipe buffer holds (64KB) blocks in
/// `write` until someone reads — which nobody was going to, because the parent was parked
/// in `waitUntilExit()` waiting for a child that could never exit. `git worktree list
/// --porcelain` in a repository with enough worktrees is exactly that much output, and
/// the symptom is not a slow picker but a `git` that never returns and a task that never
/// completes.
///
/// Draining them one after the other has the same bug one level down (filling stderr
/// while the reader is blocked on stdout), hence `async let` rather than two sequential
/// reads. By the time both have hit EOF the child has closed its descriptors, so the
/// `waitUntilExit()` that follows is a formality rather than a wait.
@discardableResult
private func run(_ executable: String, _ arguments: [String]) async throws -> String {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  process.arguments = [executable] + arguments

  let stdout = Pipe()
  let stderr = Pipe()
  process.standardOutput = stdout
  process.standardError = stderr

  try process.run()

  async let outputData = drain(stdout)
  async let errorData = drain(stderr)
  let output = String(bytes: await outputData, encoding: .utf8) ?? ""
  let errorOutput = String(bytes: await errorData, encoding: .utf8) ?? ""

  process.waitUntilExit()

  guard process.terminationStatus == 0 else {
    throw GitClientError.commandFailed(
      command: (["git"] + arguments).joined(separator: " "),
      status: process.terminationStatus,
      output: errorOutput.isEmpty ? output : errorOutput
    )
  }
  return output
}

/// Reads a pipe to EOF without occupying a thread while it waits.
///
/// `readDataToEndOfFile()` would be shorter, but it blocks its caller for the whole life
/// of the child — and the caller here is a cooperative-pool thread, of which there are
/// only as many as the machine has cores. Two of them parked per `git` invocation is how
/// a handful of concurrent calls stall every other Swift concurrency task in the app,
/// terminal effects included.
private func drain(_ pipe: Pipe) async -> Data {
  final class Buffer: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: Data())
    func append(_ chunk: Data) { lock.withLock { $0.append(chunk) } }
    var value: Data { lock.withLock { $0 } }
  }

  let buffer = Buffer()
  return await withCheckedContinuation { continuation in
    let handle = pipe.fileHandleForReading
    handle.readabilityHandler = { handle in
      let chunk = handle.availableData
      guard chunk.isEmpty else {
        buffer.append(chunk)
        return
      }
      // Empty read means EOF: stop listening before resuming, so a late callback can't
      // resume the same continuation twice.
      handle.readabilityHandler = nil
      continuation.resume(returning: buffer.value)
    }
  }
}
