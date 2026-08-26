import Foundation

/// A loop's memory across passes and relaunches: one append-only log per node, plus a
/// budgeted "wake digest" the next session is pointed at before it starts.
///
/// Without this, every relaunched session opened with the same static prompt as pass
/// one — no idea what was already tried, what the critic rejected, or how the metric
/// has been trending. The design follows OptMem's split: the **log is the truth**
/// (append-only, never edited, unbounded), and anything derived from it — the wake
/// digest here — is a bounded, rebuildable cache. What enters the loop's context is
/// governed by a *reading* budget (`wakeLineBudget`), not by how much has been stored.
///
/// Two writers, one log:
/// - `graphcoded` appends objective episode records (pass started, resolved, metric
///   readings, staged hand-offs) via `GraphStore`'s `onAppendMemory` hook — facts that
///   exist even when a session crashed and can't be trusted to self-report.
/// - The session itself appends learned notes through `graphcode node memo …` — the
///   *why* only the agent knows.
///
/// Files live under the support directory, never inside the user's project: graphcode
/// never writes into an opened folder, and a log in the worktree would be clobbered by
/// the very git operations the loop performs.
///
/// The digest is delivered by *path*, the `SessionBriefing` lesson: a typed launch
/// command tops out under `MAX_CANON`, so the pointer is ~90 bytes and the file is free
/// to be as long as its budget allows.
public enum NodeMemory {
  public static let logFileName = "LOG.txt"
  public static let wakeFileName = "WAKE.md"
  public static let promptFileName = "PROMPT.md"
  /// The node's refinable supplemental prompt — the continual-harness half of memory.
  /// The log records what *happened*; the playbook is what the loop has distilled about
  /// *how to do this job*, rewritten whole by `graphcode node refine` and carried into
  /// every wake digest. Distinct from `PROMPT.md`, which is the launch path's delivery
  /// vehicle for an oversized opening prompt, and from the briefing, which is the
  /// immutable base no refinement may touch.
  public static let playbookFileName = "PLAYBOOK.md"

  /// How many recent log lines a wake digest carries verbatim (~a few KB). Older
  /// entries are elided with a pointer at the full log — available on demand, out of
  /// the default view.
  public static let wakeLineBudget = 40

  /// Notes are capped the way OptMem caps them: forcing salience at write time is what
  /// keeps the log a memory rather than a transcript.
  public static let maxEntryBytes = 512

  /// The playbook's write-time bound, an order of magnitude looser than a log entry's
  /// because it is a *document* the loop maintains — but still a bound, because the
  /// whole file rides into every wake digest and an unbounded playbook would grow into
  /// exactly the transcript the digest budget exists to keep out.
  public static let maxPlaybookBytes = 8192

  /// How many superseded playbooks are kept for rollback. Refinement is supposed to be
  /// small, evidence-backed steps; five steps of undo covers a bad session's worth.
  public static let playbookSnapshotLimit = 5

  /// One directory per (project, node). The project component reuses
  /// `SessionBriefing.slug` so a human browsing `~/.graphcode/memory` can tell which
  /// project a log belongs to.
  public static func directory(
    forProjectPath projectPath: String, nodeID: UUID, baseURL: URL = SupportDirectory.url
  ) -> URL {
    baseURL
      .appendingPathComponent("memory", isDirectory: true)
      .appendingPathComponent(SessionBriefing.slug(for: projectPath), isDirectory: true)
      .appendingPathComponent(nodeID.uuidString, isDirectory: true)
  }

  public static func logURL(
    forProjectPath projectPath: String, nodeID: UUID, baseURL: URL = SupportDirectory.url
  ) -> URL {
    directory(forProjectPath: projectPath, nodeID: nodeID, baseURL: baseURL)
      .appendingPathComponent(logFileName)
  }

  /// Appends one timestamped entry. Newlines are flattened — the log is line-oriented,
  /// and an entry that could smuggle a line break would corrupt every reader. Oversized
  /// entries are truncated, not refused: a partial memory beats a lost one.
  ///
  /// Failures are swallowed for the same reason `SessionBriefing.write`'s are: a loop
  /// with no memory is the pre-memory behaviour, which works, where failing the
  /// operation that tried to record something would trade a note for a loop.
  public static func append(
    _ entry: String, projectPath: String, nodeID: UUID, baseURL: URL = SupportDirectory.url
  ) {
    let flattened =
      entry
      .replacingOccurrences(of: "\r\n", with: " ")
      .replacingOccurrences(of: "\r", with: " ")
      .replacingOccurrences(of: "\n", with: " ")
      .trimmingCharacters(in: .whitespaces)
    guard !flattened.isEmpty else { return }
    let capped =
      flattened.utf8.count <= maxEntryBytes
      ? flattened
      : String(decoding: Array(flattened.utf8.prefix(maxEntryBytes)), as: UTF8.self)
    let line = "\(Date().ISO8601Format())  \(capped)\n"

    let url = logURL(forProjectPath: projectPath, nodeID: nodeID, baseURL: baseURL)
    let fileManager = FileManager.default
    do {
      try fileManager.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      if !fileManager.fileExists(atPath: url.path) {
        try line.write(to: url, atomically: true, encoding: .utf8)
        return
      }
      let handle = try FileHandle(forWritingTo: url)
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: Data(line.utf8))
    } catch {
      return
    }
  }

  /// Every entry, oldest first. The full history — `recall`, not `wake`.
  public static func entries(
    forProjectPath projectPath: String, nodeID: UUID, baseURL: URL = SupportDirectory.url
  ) -> [String] {
    let url = logURL(forProjectPath: projectPath, nodeID: nodeID, baseURL: baseURL)
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    return text.split(whereSeparator: \.isNewline).map(String.init)
  }

  /// Writes the wake digest — the budgeted view a fresh session reads before starting —
  /// and returns its path, or `nil` when the node has no memory yet (a first launch
  /// should not be told to go read an empty file).
  ///
  /// Rewritten on every launch rather than cached, like the briefing: one small write
  /// per session start, and the digest can never go stale against a log that grew
  /// underneath it.
  public static func writeWakeDigest(
    projectPath: String, nodeID: UUID, baseURL: URL = SupportDirectory.url
  ) -> URL? {
    let all = entries(forProjectPath: projectPath, nodeID: nodeID, baseURL: baseURL)
    let playbook = playbook(forProjectPath: projectPath, nodeID: nodeID, baseURL: baseURL)
    // A playbook alone still earns a digest: refinement is exactly the knowledge a
    // fresh session must start from, log or no log.
    guard !all.isEmpty || playbook != nil else { return nil }

    let recent = all.suffix(wakeLineBudget)
    let elided = all.count - recent.count
    let logPath = logURL(forProjectPath: projectPath, nodeID: nodeID, baseURL: baseURL).path

    var lines: [String] = [
      "# Loop memory",
      "",
      "What has happened to this loop across its passes, oldest first. Read it before",
      "working: do not re-try what is recorded as a dead end, and continue from where",
      "the last pass left off. Record anything you learn that a future pass must know",
      "with: graphcode node memo <project-path> <your-node-id> <note>",
      "",
    ]
    if let playbook {
      // The playbook rides ahead of the history: it is the distilled *how*, where the
      // log is the raw *what happened*, and a session should read method before events.
      lines.append("## Your playbook")
      lines.append("")
      lines.append("Written by your own earlier passes. Follow it, and when this pass")
      lines.append("teaches you a better way of working, rewrite it (whole document) with:")
      lines.append("graphcode node refine <project-path> <your-node-id> <new playbook text>")
      lines.append("")
      lines.append(playbook)
      lines.append("")
      lines.append("## Recent history")
      lines.append("")
    }
    if elided > 0 {
      lines.append("(\(elided) earlier entries elided — full log: \(logPath))")
      lines.append("")
    }
    lines.append(contentsOf: recent)
    let digest = lines.joined(separator: "\n") + "\n"

    let url = directory(forProjectPath: projectPath, nodeID: nodeID, baseURL: baseURL)
      .appendingPathComponent(wakeFileName)
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try digest.write(to: url, atomically: true, encoding: .utf8)
      return url
    } catch {
      return nil
    }
  }

  public static func playbookURL(
    forProjectPath projectPath: String, nodeID: UUID, baseURL: URL = SupportDirectory.url
  ) -> URL {
    directory(forProjectPath: projectPath, nodeID: nodeID, baseURL: baseURL)
      .appendingPathComponent(playbookFileName)
  }

  /// The playbook's current text, or `nil` when the node has never refined one — the
  /// wake digest uses the distinction to omit the section entirely rather than show an
  /// empty heading.
  public static func playbook(
    forProjectPath projectPath: String, nodeID: UUID, baseURL: URL = SupportDirectory.url
  ) -> String? {
    let url = playbookURL(forProjectPath: projectPath, nodeID: nodeID, baseURL: baseURL)
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  /// Replaces the playbook, snapshotting what it replaced — `graphcode node refine`'s
  /// write half. Whole-document replacement rather than patching, because the loop
  /// authoring it holds the old text in context anyway and a patch language would be a
  /// second thing to get wrong; the snapshots are what make replacement safe.
  ///
  /// Returns false — and writes nothing — for empty text (that is what rollback is
  /// for) or text over `maxPlaybookBytes`: unlike a memo, a playbook truncated
  /// mid-sentence would be *followed* in its corrupted form on every future wake, so
  /// oversize is refused loudly at the daemon rather than trimmed quietly here.
  public static func refinePlaybook(
    _ text: String, projectPath: String, nodeID: UUID, baseURL: URL = SupportDirectory.url
  ) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.utf8.count <= maxPlaybookBytes else { return false }
    let url = playbookURL(forProjectPath: projectPath, nodeID: nodeID, baseURL: baseURL)
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      if FileManager.default.fileExists(atPath: url.path) {
        try snapshotPlaybook(at: url)
      }
      try (trimmed + "\n").write(to: url, atomically: true, encoding: .utf8)
      return true
    } catch {
      return false
    }
  }

  /// Restores the newest snapshot as the current playbook and consumes it — undo, one
  /// step at a time, up to `playbookSnapshotLimit` steps. Returns false when there is
  /// nothing to roll back to.
  public static func rollbackPlaybook(
    projectPath: String, nodeID: UUID, baseURL: URL = SupportDirectory.url
  ) -> Bool {
    let url = playbookURL(forProjectPath: projectPath, nodeID: nodeID, baseURL: baseURL)
    guard let newest = playbookSnapshots(besidePlaybookAt: url).last else { return false }
    do {
      if FileManager.default.fileExists(atPath: url.path) {
        try FileManager.default.removeItem(at: url)
      }
      try FileManager.default.moveItem(at: newest, to: url)
      return true
    } catch {
      return false
    }
  }

  /// Copies the current playbook aside as `PLAYBOOK.<sequence>.md` and prunes the
  /// oldest beyond the limit. The sequence is one past the newest existing snapshot's,
  /// so names stay ordered however many rollbacks have consumed the middle.
  private static func snapshotPlaybook(at url: URL) throws {
    let existing = playbookSnapshots(besidePlaybookAt: url)
    let next = (existing.last.flatMap(snapshotSequence) ?? 0) + 1
    let snapshot = url.deletingLastPathComponent()
      .appendingPathComponent("PLAYBOOK.\(next).md")
    try FileManager.default.copyItem(at: url, to: snapshot)
    for stale in existing.dropLast(playbookSnapshotLimit - 1) {
      try? FileManager.default.removeItem(at: stale)
    }
  }

  /// Existing snapshots, oldest first.
  private static func playbookSnapshots(besidePlaybookAt url: URL) -> [URL] {
    let directory = url.deletingLastPathComponent()
    let contents =
      (try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)) ?? []
    return
      contents
      .filter { snapshotSequence($0) != nil }
      .sorted { (snapshotSequence($0) ?? 0) < (snapshotSequence($1) ?? 0) }
  }

  private static func snapshotSequence(_ url: URL) -> Int? {
    let name = url.lastPathComponent
    guard name.hasPrefix("PLAYBOOK."), name.hasSuffix(".md") else { return nil }
    return Int(name.dropFirst("PLAYBOOK.".count).dropLast(".md".count))
  }

  /// Writes a node's full prompt to its `PROMPT.md` and returns where it landed, or
  /// `nil` when writing failed.
  ///
  /// This is the launch path's last-resort delivery for a prompt too long to type: the
  /// command `zmx` types into a session tops out under `MAX_CANON` (1024 bytes), and a
  /// multi-KB goal overran it — the tty ate the tail mid-word, the shell parked at a
  /// continuation prompt, and the node read `running` while no backend process existed
  /// (issue #57). A file has no length limit, so the goal rides here and the typed line
  /// carries only `promptPointer`.
  ///
  /// It lives beside the wake digest deliberately: same per-node lifecycle (`remove`
  /// cleans both), same remote delivery channel, and the directory is already what a
  /// path-verifying backend gets granted.
  public static func writePrompt(
    _ text: String, projectPath: String, nodeID: UUID, baseURL: URL = SupportDirectory.url
  ) -> URL? {
    let url = directory(forProjectPath: projectPath, nodeID: nodeID, baseURL: baseURL)
      .appendingPathComponent(promptFileName)
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try text.write(to: url, atomically: true, encoding: .utf8)
      return url
    } catch {
      return nil
    }
  }

  /// What gets typed in the prompt's place. ASCII only, plain words on both sides of
  /// the path — this string rides the same hostile route as the briefing pointer
  /// (argv, zmx's typed command line, a canonical-mode tty, sometimes ssh), where an
  /// em dash next to the path once ate the file extension (`SessionBriefing.pointer`).
  public static func promptPointer(toPromptAt path: String) -> String {
    "Your complete instructions are in the file at \(path) - read that file first and "
      + "carry out everything it says."
  }

  /// What points a waking session at its own digest. Self-contained rather than a
  /// "…, then:" joiner, because `SessionPrompt` may put it on either side of the prompt:
  /// a time-based node's prompt is the `/loop …` directive, which stops being a command
  /// the moment anything precedes it (issue #179).
  public static func wakePointer(toDigestAt path: String) -> String {
    "Read your loop memory at \(path) before starting."
  }

  static let firstPassFileName = "FIRST-PASS.txt"

  /// Which of this node's sessions has already been given its opening pass
  /// (`ZmxSessionLauncher.kickOffFirstPass`), identified by the Copilot session directory
  /// it was typed into.
  ///
  /// Persisted rather than held in memory because the thing it must not do is repeat: the
  /// daemon restarts, ensure ticks run again, and a task typed twice is a loop that did
  /// its work twice. A *new* Copilot session has a new directory and so is never mistaken
  /// for one already served.
  public static func firstPassMarker(
    projectPath: String, nodeID: UUID, baseURL: URL = SupportDirectory.url
  ) -> String? {
    let url = directory(forProjectPath: projectPath, nodeID: nodeID, baseURL: baseURL)
      .appendingPathComponent(firstPassFileName)
    return (try? String(contentsOf: url, encoding: .utf8))?
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public static func recordFirstPass(
    _ marker: String, projectPath: String, nodeID: UUID, baseURL: URL = SupportDirectory.url
  ) {
    let directory = directory(forProjectPath: projectPath, nodeID: nodeID, baseURL: baseURL)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try? Data(marker.utf8).write(
      to: directory.appendingPathComponent(firstPassFileName), options: .atomic)
  }

  /// Forgotten when the session is torn down: the next one is a new session and has had
  /// no pass of its own.
  public static func clearFirstPass(
    projectPath: String, nodeID: UUID, baseURL: URL = SupportDirectory.url
  ) {
    try? FileManager.default.removeItem(
      at: directory(forProjectPath: projectPath, nodeID: nodeID, baseURL: baseURL)
        .appendingPathComponent(firstPassFileName))
  }

  /// Removes a node's memory directory — called when the node itself is deleted, the
  /// same moment its session is torn down. A log for a loop that no longer exists is
  /// not history, it's litter.
  public static func remove(
    projectPath: String, nodeID: UUID, baseURL: URL = SupportDirectory.url
  ) {
    try? FileManager.default.removeItem(
      at: directory(forProjectPath: projectPath, nodeID: nodeID, baseURL: baseURL))
  }
}
