import Dependencies
import Foundation
import GraphcodeKit
import os

/// Graphcode's own minimal git client — worktrees, and cloning a remote repository so a
/// project can be added straight from a URL. It is not a general git porcelain layer.
/// See docs/03-architecture.md and docs/07-roadmap.md#phase-1--single-loop-manual-check.
struct GitClient: Sendable {
  var createWorktree:
    @Sendable (_ repositoryPath: String, _ worktreePath: String, _ branch: String) async throws ->
      WorktreeRef
  var listWorktrees: @Sendable (_ repositoryPath: String) async throws -> [WorktreeRef]
  var removeWorktree: @Sendable (_ worktree: WorktreeRef) async throws -> Void
  /// Reads every linked worktree's hygiene signals — landed, clean, pushed, prunable —
  /// in one call. The primary checkout is never a candidate and is not returned.
  ///
  /// **Never sizes.** `du` over a worktree walks its whole tree, and a repository with
  /// dozens of worktrees turned the sweeper's spinner into a half-hour wait for facts
  /// git answers in seconds. Sizes come one at a time from `worktreeSizeBytes`, after
  /// the rows are already on screen.
  var inspectWorktrees: @Sendable (_ repositoryPath: String) async throws -> [WorktreeInspection]
  /// One worktree's on-disk size, for callers to stream in after the facts.
  var worktreeSizeBytes: @Sendable (_ worktreePath: String) async -> Int64?
  /// Removes a worktree and deletes its branch. A prunable entry (admin file, no
  /// directory) is pruned instead of removed. `force` is for a dirty tree the human
  /// explicitly confirmed losing — without it git refuses uncommitted files, which is
  /// the default's safety.
  var removeWorktreeAndBranch:
    @Sendable (_ worktree: WorktreeRef, _ prunable: Bool, _ force: Bool) async throws -> Void
  /// Streams a `git clone --progress` into `destination`: progress lines while it runs,
  /// `.finished` on success, a thrown `GitClientError` on failure. Streaming is what lets
  /// the form show a live percentage instead of a spinner over a multi-minute network
  /// operation.
  var clone:
    @Sendable (_ url: String, _ destination: URL, _ branch: String?, _ depth: Int?) ->
      AsyncThrowingStream<GitCloneEvent, any Error>
}

enum GitCloneEvent: Equatable, Sendable {
  case progress(String)
  case finished
}

/// One linked worktree with its git facts attached — what the sweeper classifies.
struct WorktreeInspection: Equatable, Sendable {
  var ref: WorktreeRef
  var facts: WorktreeGitFacts
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
    },
    inspectWorktrees: { repositoryPath in
      let output = try await run("git", ["-C", repositoryPath, "worktree", "list", "--porcelain"])
      let repoPath = resolvedPath(repositoryPath)
      let blocks = parseWorktreeBlocks(output)
        .filter { $0.branch != nil && resolvedPath($0.path) != repoPath }
      let defaultBranch = await discoverDefaultBranch(repositoryPath)
      // Concurrent, bounded: serial inspection scaled linearly with the backlog — the
      // repositories that need the sweeper most were the ones it was slowest on. Six
      // at a time keeps the process count civil (each inspection is up to three gits).
      var inspections = [WorktreeInspection?](repeating: nil, count: blocks.count)
      await withTaskGroup(of: (Int, WorktreeInspection)?.self) { group in
        var next = 0
        func submit() {
          guard next < blocks.count else { return }
          let index = next
          let block = blocks[index]
          next += 1
          group.addTask {
            guard let branch = block.branch else { return nil }
            let ref = WorktreeRef(
              id: branch, repositoryPath: repositoryPath, worktreePath: block.path,
              branch: branch)
            let facts = await gitFacts(
              for: block, defaultBranch: defaultBranch, repositoryPath: repositoryPath)
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
    worktreeSizeBytes: { worktreePath in
      (try? await run("du", ["-sk", worktreePath]))
        .flatMap { $0.split(separator: "\t").first }
        .flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) }
        .map { $0 * 1024 }
    },
    removeWorktreeAndBranch: { worktree, prunable, force in
      if prunable {
        _ = try await run("git", ["-C", worktree.repositoryPath, "worktree", "prune"])
      } else {
        var arguments = ["-C", worktree.repositoryPath, "worktree", "remove"]
        if force { arguments.append("--force") }
        arguments.append(worktree.worktreePath)
        _ = try await run("git", arguments)
      }
      // `-D`, not `-d`: the landed check was `git cherry`, which counts squash merges —
      // exactly the branches `-d` would refuse. The reflog keeps the tip recoverable.
      // A branch that is already gone shouldn't fail a removal that succeeded.
      _ = try? await run("git", ["-C", worktree.repositoryPath, "branch", "-D", worktree.branch])
    },
    clone: { url, destination, branch, depth in
      runClone(url: url, destination: destination, branch: branch, depth: depth)
    }
  )
}

extension GitClient {
  /// Git's own "humanish" directory name for a clone URL — the last path component with
  /// `.git` stripped. Parsed from the raw string because scp-style remotes
  /// (`git@host:org/repo.git`) are not URLs Foundation can take apart. Empty when no
  /// leaf derives, which the form treats as "nothing to prefill".
  static func humanishName(forCloneURL url: String) -> String {
    var trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
    if let queryIndex = trimmed.firstIndex(where: { $0 == "?" || $0 == "#" }) {
      trimmed = String(trimmed[..<queryIndex])
    }
    while trimmed.hasSuffix("/") { trimmed.removeLast() }
    if let separatorIndex = trimmed.lastIndex(where: { $0 == "/" || $0 == ":" }) {
      trimmed = String(trimmed[trimmed.index(after: separatorIndex)...])
    }
    if trimmed.hasSuffix(".git") { trimmed.removeLast(4) }
    return trimmed
  }

  /// The secret userinfo of an http(s) clone URL (`token` or `user:password`), so it can
  /// be blanked out of every progress line and error shown to a human. An ssh user
  /// (`git@host`) is a login name, not a secret, and URLComponents doesn't parse
  /// scp-style remotes anyway — both fall out as nil.
  static func cloneCredentials(of url: String) -> String? {
    guard let components = URLComponents(string: url),
      let user = components.percentEncodedUser, !user.isEmpty
    else { return nil }
    guard let password = components.percentEncodedPassword, !password.isEmpty else {
      return user
    }
    return "\(user):\(password)"
  }
}

/// The live `clone` implementation. Progress arrives on stderr in `\r`-separated
/// updates (git redraws one line in place), so the reader splits on both `\r` and `\n`
/// and yields each completed piece.
private func runClone(
  url: String, destination: URL, branch: String?, depth: Int?
) -> AsyncThrowingStream<GitCloneEvent, any Error> {
  AsyncThrowingStream { continuation in
    let destinationPath = destination.standardizedFileURL.path
    // Only a directory the clone itself created is ours to remove on failure — a
    // pre-existing one (git will refuse it anyway if non-empty) is the user's.
    let existedBefore = FileManager.default.fileExists(atPath: destinationPath)
    let credentials = GitClient.cloneCredentials(of: url)

    let process = cloneProcess(
      url: url, destinationPath: destinationPath, branch: branch, depth: depth)
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    // Collected for the error message: git's explanation of a failure is its last few
    // stderr lines, and `commandFailed` should carry them rather than a bare status.
    let recentLines = OSAllocatedUnfairLock(initialState: [String]())
    let onLine: @Sendable (String) -> Void = { line in
      let shown =
        credentials.map { line.replacingOccurrences(of: $0, with: "•••") } ?? line
      recentLines.withLock { recent in
        recent.append(shown)
        if recent.count > 5 { recent.removeFirst() }
      }
      continuation.yield(.progress(shown))
    }
    attachLineReader(to: stdout, onLine: onLine)
    attachLineReader(to: stderr, onLine: onLine)

    process.terminationHandler = { process in
      stdout.fileHandleForReading.readabilityHandler = nil
      stderr.fileHandleForReading.readabilityHandler = nil
      if process.terminationStatus == 0 {
        continuation.yield(.finished)
        continuation.finish()
        return
      }
      // A failed clone that created the directory leaves a partial repo the next
      // attempt would refuse; remove what this run made and nothing else.
      if !existedBefore {
        try? FileManager.default.removeItem(atPath: destinationPath)
      }
      continuation.finish(
        throwing: GitClientError.commandFailed(
          command: "git clone",
          status: process.terminationStatus,
          output: recentLines.withLock { $0.joined(separator: "\n") }))
    }

    continuation.onTermination = { reason in
      // The sheet was dismissed mid-clone: end the process; its termination handler
      // then does the partial-clone cleanup.
      if case .cancelled = reason, process.isRunning { process.terminate() }
    }

    do {
      try process.run()
    } catch {
      continuation.finish(throwing: error)
    }
  }
}

/// The `git clone` invocation, environment included.
private func cloneProcess(
  url: String, destinationPath: String, branch: String?, depth: Int?
) -> Process {
  var arguments = ["git", "clone", "--progress"]
  if let branch, !branch.isEmpty { arguments += ["--branch", branch] }
  if let depth { arguments += ["--depth", String(depth)] }
  arguments += [url, destinationPath]

  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  process.arguments = arguments
  var environment = ProcessInfo.processInfo.environment
  // No tty means no one to answer a prompt: fail fast on credentials and host keys
  // instead of hanging the sheet on a question it can never show.
  environment["GIT_TERMINAL_PROMPT"] = "0"
  environment["GIT_SSH_COMMAND"] =
    "ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new"
  // Untranslated output, so the progress parsing and the errors people paste into
  // issues are the same everywhere.
  environment["LC_ALL"] = "C"
  process.environment = environment
  return process
}

/// Feeds `onLine` every completed line out of `pipe`, treating `\r` (git's redraw-in-
/// place separator) the same as `\n`, and dropping blanks.
private func attachLineReader(to pipe: Pipe, onLine: @escaping @Sendable (String) -> Void) {
  let remainder = OSAllocatedUnfairLock(initialState: "")
  pipe.fileHandleForReading.readabilityHandler = { handle in
    let chunk = handle.availableData
    guard !chunk.isEmpty else {
      handle.readabilityHandler = nil
      return
    }
    guard let text = String(data: chunk, encoding: .utf8) else { return }
    let pieces = remainder.withLock { remainder in
      var buffered = remainder + text
      var lines: [String] = []
      while let breakIndex = buffered.firstIndex(where: { $0 == "\r" || $0 == "\n" }) {
        lines.append(String(buffered[..<breakIndex]))
        buffered = String(buffered[buffered.index(after: breakIndex)...])
      }
      remainder = buffered
      return lines
    }
    for piece in pieces {
      let line = piece.trimmingCharacters(in: .whitespaces)
      if !line.isEmpty { onLine(line) }
    }
  }
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
  parseWorktreeBlocks(output).compactMap { block in
    guard let branch = block.branch else { return nil }
    return WorktreeRef(
      id: branch, repositoryPath: repositoryPath, worktreePath: block.path, branch: branch)
  }
}

private struct WorktreeBlock {
  var path: String
  var branch: String?
  var prunable = false
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
    } else if line.hasPrefix("prunable") {
      current?.prunable = true
    }
  }
  flush()
  return blocks
}

private func resolvedPath(_ path: String) -> String {
  URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
}

/// The branch `landed` is measured against: `origin/HEAD` when the remote declares one,
/// then a local `main`/`master`, then whatever the primary checkout is on.
private func discoverDefaultBranch(_ repositoryPath: String) async -> String {
  if let head = try? await run(
    "git", ["-C", repositoryPath, "symbolic-ref", "--short", "refs/remotes/origin/HEAD"])
  {
    let name = head.trimmingCharacters(in: .whitespacesAndNewlines)
    if let slash = name.firstIndex(of: "/") {
      return String(name[name.index(after: slash)...])
    }
  }
  for candidate in ["main", "master"]
  where
    (try? await run(
      "git", ["-C", repositoryPath, "rev-parse", "--verify", "--quiet", "refs/heads/\(candidate)"]))
    != nil
  {
    return candidate
  }
  let current =
    (try? await run("git", ["-C", repositoryPath, "symbolic-ref", "--short", "HEAD"])) ?? "main"
  return current.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Reads one worktree's signals. Every read fails toward the cautious answer — an
/// unreadable status counts as dirty, a failed cherry as unlanded, a missing upstream
/// as unpushed — so a git hiccup can only move a worktree *out* of the safe tier.
private func gitFacts(
  for block: WorktreeBlock, defaultBranch: String, repositoryPath: String
) async -> WorktreeGitFacts {
  if block.prunable {
    return WorktreeGitFacts(
      defaultBranch: defaultBranch, commitsNotLanded: 0, dirtyFileCount: 0, pushed: true,
      prunable: true)
  }
  let branch = block.branch ?? ""
  let cherry =
    (try? await run("git", ["-C", repositoryPath, "cherry", defaultBranch, branch])) ?? "+"
  let commitsNotLanded = cherry.split(separator: "\n").filter { $0.hasPrefix("+") }.count
  let status = try? await run("git", ["-C", block.path, "status", "--porcelain"])
  let dirtyFileCount = status.map { $0.split(separator: "\n").count } ?? 1
  let ahead = try? await run(
    "git", ["-C", block.path, "rev-list", "--count", "@{upstream}..HEAD"])
  let pushed =
    ahead.flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } == 0
  return WorktreeGitFacts(
    defaultBranch: defaultBranch, commitsNotLanded: commitsNotLanded,
    dirtyFileCount: dirtyFileCount, pushed: pushed, prunable: false, sizeBytes: nil)
}

/// Runs a command and returns its standard output.
///
/// **Both pipes are drained before the exit status is read, and concurrently with each
/// other.** The order matters and the previous order deadlocked: waiting came first,
/// and a child that writes more than the pipe buffer holds (64KB) blocks in `write`
/// until someone reads — which nobody was going to, because the parent was parked
/// waiting for a child that could never exit. `git worktree list --porcelain` in a
/// repository with enough worktrees is exactly that much output, and the symptom is not
/// a slow picker but a `git` that never returns and a task that never completes.
///
/// Draining them one after the other has the same bug one level down (filling stderr
/// while the reader is blocked on stdout), hence `async let` rather than two sequential
/// reads.
///
/// **The exit is awaited through `terminationHandler`, never `waitUntilExit()`.** That
/// call blocks its thread, and the thread it blocked was sometimes the main one —
/// worktree inspection runs off a `graphChanged` broadcast, and a missed termination
/// event parked the whole app (and the hosted test runner) inside a wait for a child
/// that had already exited. The handler is installed before `run()` so the exit can't
/// be missed, and it resumes a continuation from Foundation's own background queue —
/// nothing anywhere blocks.
@discardableResult
private func run(_ executable: String, _ arguments: [String]) async throws -> String {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  process.arguments = [executable] + arguments

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

  async let outputData = drain(stdout)
  async let errorData = drain(stderr)
  let output = String(bytes: await outputData, encoding: .utf8) ?? ""
  let errorOutput = String(bytes: await errorData, encoding: .utf8) ?? ""

  var status: Int32 = -1
  for await exitStatus in exited { status = exitStatus }

  guard status == 0 else {
    throw GitClientError.commandFailed(
      command: (["git"] + arguments).joined(separator: " "),
      status: status,
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
