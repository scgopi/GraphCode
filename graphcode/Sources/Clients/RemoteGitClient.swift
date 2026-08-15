import Dependencies
import Foundation
import GraphcodeKit
import os

/// Git operations for a remote repository — the SSH-executed twin of `GitClient`. Every
/// operation here runs `git` on the remote host through the location's SSH invocation,
/// paying the network round trip that makes local operations cheap.
///
/// The client is stateless: each call parses the project path to discover whether it's
/// remote, so callers don't need to branch — just call whichever operation they need and
/// the right transport is chosen.
struct RemoteGitClient: Sendable {
  /// Reads every linked worktree's hygiene signals over SSH. The same facts as the local
  /// `inspectWorktrees`, but each git command is an SSH round trip.
  var inspectWorktrees:
    @Sendable (_ location: RemoteProjectLocation) async throws -> [WorktreeInspection]
  /// One worktree's on-disk size, run as `du -sk` over SSH.
  var worktreeSizeBytes:
    @Sendable (_ location: RemoteProjectLocation, _ worktreePath: String) async
      -> Int64?
  /// Removes a worktree and deletes its branch over SSH.
  var removeWorktreeAndBranch:
    @Sendable (
      _ location: RemoteProjectLocation, _ worktree: WorktreeRef, _ prunable: Bool, _ force: Bool
    ) async throws -> Void
  /// Clears a `git worktree lock` over SSH.
  var unlockWorktree:
    @Sendable (_ location: RemoteProjectLocation, _ worktreePath: String) async throws -> Void
}

extension RemoteGitClient: DependencyKey {
  static let liveValue = RemoteGitClient(
    inspectWorktrees: { location in
      let quoted = RemoteProjectLocation.shellQuoted
      let listCommand = "git -C \(quoted(location.remotePath)) worktree list --porcelain"
      let output = try await runSSH(location, listCommand)
      let repositoryPath = await canonicalRepositoryPath(location)
      let blocks = parseWorktreeBlocks(output)
        .filter { RemoteProjectLocation.normalizedPath($0.path) != repositoryPath }
      let defaultBranch = await discoverDefaultBranch(location)
      var inspections = [WorktreeInspection?](repeating: nil, count: blocks.count)
      await withTaskGroup(of: (Int, WorktreeInspection)?.self) { group in
        var next = 0
        func submit() {
          guard next < blocks.count else { return }
          let index = next
          let block = blocks[index]
          next += 1
          group.addTask {
            let ref = WorktreeRef(
              id: block.branch ?? block.path, repositoryPath: location.projectPath,
              worktreePath: block.path, branch: block.branch ?? "")
            let facts = await remoteGitFacts(
              for: block, defaultBranch: defaultBranch, location: location)
            return (index, WorktreeInspection(ref: ref, facts: facts))
          }
        }
        for _ in 0..<min(6, blocks.count) { submit() }
        for await result in group {
          if let (index, inspection) = result { inspections[index] = inspection }
          submit()
        }
      }
      return inspections.compactMap { $0 }
    },
    worktreeSizeBytes: { location, worktreePath in
      let quoted = RemoteProjectLocation.shellQuoted
      let command = "du -sk \(quoted(worktreePath))"
      return (try? await runSSH(location, command))
        .flatMap { $0.split(separator: "\t").first }
        .flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) }
        .map { $0 * 1024 }
    },
    removeWorktreeAndBranch: { location, worktree, prunable, force in
      let quoted = RemoteProjectLocation.shellQuoted
      let tip =
        worktree.branch.isEmpty
        ? nil
        : (try? await runSSH(
          location,
          "git -C \(quoted(location.remotePath)) rev-parse refs/heads/\(quoted(worktree.branch))"))?
          .trimmingCharacters(in: .whitespacesAndNewlines)

      if prunable {
        _ = try await runSSH(location, "git -C \(quoted(location.remotePath)) worktree prune")
      } else {
        var command = "git -C \(quoted(location.remotePath)) worktree remove"
        if force { command += " --force" }
        command += " \(quoted(worktree.worktreePath))"
        _ = try await runSSH(location, command)
      }
      guard !worktree.branch.isEmpty else { return }
      _ = try? await runSSH(
        location, "git -C \(quoted(location.remotePath)) branch -D \(quoted(worktree.branch))")
      if let tip, !tip.isEmpty {
        appendRemovedBranchRecord(
          branch: worktree.branch, tip: tip, path: worktree.worktreePath, host: location.host)
      }
    },
    unlockWorktree: { location, worktreePath in
      let quoted = RemoteProjectLocation.shellQuoted
      _ = try await runSSH(
        location,
        "git -C \(quoted(location.remotePath)) worktree unlock \(quoted(worktreePath))")
    }
  )

  static let testValue = RemoteGitClient(
    inspectWorktrees: { _ in [] },
    worktreeSizeBytes: { _, _ in nil },
    removeWorktreeAndBranch: { _, _, _, _ in },
    unlockWorktree: { _, _ in }
  )
}

extension DependencyValues {
  var remoteGitClient: RemoteGitClient {
    get { self[RemoteGitClient.self] }
    set { self[RemoteGitClient.self] = newValue }
  }
}

// MARK: - SSH command execution

private func runSSH(_ location: RemoteProjectLocation, _ command: String) async throws -> String {
  RemoteProjectLocation.prepareControlSocketDirectory()
  let invocation = location.sshInvocation(remoteCommand: command)
  let process = Process()
  process.executableURL = URL(fileURLWithPath: invocation[0])
  process.arguments = Array(invocation.dropFirst())

  let stdout = Pipe()
  let stderr = Pipe()
  process.standardOutput = stdout
  process.standardError = stderr

  let (exited, exitContinuation) = AsyncStream<Int32>.makeStream()
  process.terminationHandler = { process in
    exitContinuation.yield(process.terminationStatus)
    exitContinuation.finish()
  }

  try process.run()

  async let outputData = drainPipe(stdout)
  async let errorData = drainPipe(stderr)
  let output = String(bytes: await outputData, encoding: .utf8) ?? ""
  let errorOutput = String(bytes: await errorData, encoding: .utf8) ?? ""

  var status: Int32 = -1
  for await exitStatus in exited { status = exitStatus }

  guard status == 0 else {
    throw GitClientError.commandFailed(
      command: command, status: status, output: errorOutput.isEmpty ? output : errorOutput)
  }
  return output
}

private func drainPipe(_ pipe: Pipe) async -> Data {
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
      handle.readabilityHandler = nil
      continuation.resume(returning: buffer.value)
    }
  }
}

// MARK: - Worktree parsing (shared with GitClient)

private struct WorktreeBlock {
  var path: String
  var branch: String?
  var head: String?
  var prunable = false
  var locked = false
}

private func parseWorktreeBlocks(_ output: String) -> [WorktreeBlock] {
  var blocks: [WorktreeBlock] = []
  var current: WorktreeBlock?

  func flush() {
    if let block = current { blocks.append(block) }
    current = nil
  }

  for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
    if line.isEmpty {
      flush()
    } else if line.hasPrefix("worktree ") {
      flush()
      current = WorktreeBlock(path: String(line.dropFirst("worktree ".count)))
    } else if line.hasPrefix("branch refs/heads/") {
      current?.branch = String(line.dropFirst("branch refs/heads/".count))
    } else if line.hasPrefix("HEAD ") {
      current?.head = String(line.dropFirst("HEAD ".count))
    } else if line.hasPrefix("prunable") {
      current?.prunable = true
    } else if line.hasPrefix("locked") {
      current?.locked = true
    }
  }
  flush()
  return blocks
}

// MARK: - Remote git facts

/// The spelling git itself will print for this repository, asked of the host.
///
/// The list has to drop the main working tree, and that comparison is exact. A stored
/// path can differ from git's own by a trailing slash or a symlinked parent, and when it
/// does the main repository survives the filter and reaches the sweeper as a worktree —
/// the one directory holding the whole object store, every nested worktree and every
/// build output, so it lands as a phantom row the size of the entire repository.
///
/// Falls back to the stored path normalized, which still answers the trailing slash when
/// the host cannot be reached.
private func canonicalRepositoryPath(_ location: RemoteProjectLocation) async -> String {
  let quoted = RemoteProjectLocation.shellQuoted
  let toplevel = try? await runSSH(
    location, "git -C \(quoted(location.remotePath)) rev-parse --show-toplevel")
  let path = toplevel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  return RemoteProjectLocation.normalizedPath(path.isEmpty ? location.remotePath : path)
}

private func discoverDefaultBranch(_ location: RemoteProjectLocation) async -> String {
  let quoted = RemoteProjectLocation.shellQuoted
  let repoPath = location.remotePath
  if let head = try? await runSSH(
    location, "git -C \(quoted(repoPath)) symbolic-ref --short refs/remotes/origin/HEAD")
  {
    let name = head.trimmingCharacters(in: .whitespacesAndNewlines)
    if let slash = name.firstIndex(of: "/") {
      return String(name[name.index(after: slash)...])
    }
  }
  for candidate in ["main", "master"] {
    let check = try? await runSSH(
      location,
      "git -C \(quoted(repoPath)) rev-parse --verify --quiet refs/heads/\(candidate)")
    if check != nil { return candidate }
  }
  let current =
    (try? await runSSH(location, "git -C \(quoted(repoPath)) symbolic-ref --short HEAD")) ?? "main"
  return current.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func remoteGitFacts(
  for block: WorktreeBlock, defaultBranch: String, location: RemoteProjectLocation
) async -> WorktreeGitFacts {
  let quoted = RemoteProjectLocation.shellQuoted
  let repoPath = location.remotePath
  let tip = block.branch.map { "refs/heads/\($0)" } ?? block.head
  let cherry = await tip.asyncFlatMap { tip in
    try? await runSSH(location, "git -C \(quoted(repoPath)) cherry \(defaultBranch) \(tip)")
  }
  let commitsNotLanded = (cherry ?? "+").split(separator: "\n")
    .filter { $0.hasPrefix("+") }.count

  if block.prunable {
    return WorktreeGitFacts(
      defaultBranch: defaultBranch, commitsNotLanded: commitsNotLanded, dirtyFileCount: 0,
      pushed: true, prunable: true, locked: block.locked)
  }
  let status = try? await runSSH(location, "git -C \(quoted(block.path)) status --porcelain")
  let dirtyFileCount = status.map { $0.split(separator: "\n").count } ?? 1
  let ahead = try? await runSSH(
    location, "git -C \(quoted(block.path)) rev-list --count @{upstream}..HEAD")
  let pushed = ahead.flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } == 0
  return WorktreeGitFacts(
    defaultBranch: defaultBranch, commitsNotLanded: commitsNotLanded,
    dirtyFileCount: dirtyFileCount, pushed: pushed, prunable: false, locked: block.locked,
    sizeBytes: nil)
}

private func appendRemovedBranchRecord(branch: String, tip: String, path: String, host: String) {
  let stamp = ISO8601DateFormatter().string(from: Date())
  let line = "\(stamp) \(branch) \(tip) \(path) @\(host)\n"
  guard let data = line.data(using: .utf8) else { return }
  let url = SupportDirectory.url.appendingPathComponent("removed-branches.log")
  if FileManager.default.fileExists(atPath: url.path),
    let handle = try? FileHandle(forWritingTo: url)
  {
    defer { try? handle.close() }
    _ = try? handle.seekToEnd()
    try? handle.write(contentsOf: data)
  } else {
    try? data.write(to: url)
  }
}

extension Optional {
  fileprivate func asyncFlatMap<T>(_ transform: (Wrapped) async -> T?) async -> T? {
    guard let self else { return nil }
    return await transform(self)
  }
}
