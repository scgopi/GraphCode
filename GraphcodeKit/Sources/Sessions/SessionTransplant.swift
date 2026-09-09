import Foundation

/// Moves a loop's backend conversation between machines and projects — the piece that
/// turns an imported loop from "same configuration, no memory of the conversation"
/// into "picks up where the exported one left off".
///
/// Each backend gets the most its CLI supports, which is not the same amount:
///
/// - **Claude Code** transplants fully. Its transcripts are per-project JSONL files
///   named by session id, and an id-rewritten copy dropped into the target project's
///   directory resumes with complete context (verified empirically: a transplanted
///   session recalled facts from before the move).
/// - **Copilot** transplants its whole `session-state/<id>/` directory under a fresh
///   id, text files rewritten. `--resume` restores from exactly that directory. If a
///   given Copilot build refuses the transplant, the ensure dial's resume-dead
///   fallback already starts the loop fresh — degradation, not breakage.
/// - **Codex cannot resume at all** (`supportsResume` is false), so its rollout rides
///   along as carried history — readable in the bundle, installed under
///   `~/.codex/sessions` for `codex`'s own pickers — and the imported loop's session
///   starts fresh, exactly as every Codex relaunch does.
public enum SessionTransplant {
  /// What one node's session contributes to an export bundle: the backend's own
  /// on-disk state, as relative-path → content, plus the id it was recorded under.
  public struct Artifact: Sendable {
    public let backend: CLISessionBackendKind
    /// The source machine's session id (Claude/Copilot) or rollout filename (Codex).
    /// Informational on arrival — restore rewrites it to a fresh identity.
    public let sessionID: String
    /// The working directory the session ran in, for rewriting embedded paths.
    public let sourceWorkingDirectory: String?
    public let files: [String: Data]

    public init(
      backend: CLISessionBackendKind, sessionID: String,
      sourceWorkingDirectory: String?, files: [String: Data]
    ) {
      self.backend = backend
      self.sessionID = sessionID
      self.sourceWorkingDirectory = sourceWorkingDirectory
      self.files = files
    }
  }

  // MARK: - Export

  /// The node's portable session state, or nil when there's nothing to carry: no
  /// banked session, or its files are gone.
  public static func exportArtifact(forNode node: LoopNode, projectPath: String) -> Artifact? {
    let workingDirectory = node.worktreeBinding?.worktreePath ?? projectPath
    switch node.backend {
    case .claudeCode:
      guard let sessionID = SessionIDStore.load(forNodeID: node.id) else { return nil }
      guard let url = findClaudeTranscript(sessionID: sessionID),
        let transcript = try? Data(contentsOf: url)
      else { return nil }
      return Artifact(
        backend: .claudeCode, sessionID: sessionID,
        sourceWorkingDirectory: workingDirectory,
        files: ["transcript.jsonl": transcript])

    case .copilotCLI:
      // The banked id, or the directory Copilot named after the session — the same
      // two-step lookup the ensure dial uses before resuming.
      let name = SurfaceRef(id: node.id, launchesClaudeCode: true).zmxSessionName
      guard
        let sessionID = SessionIDStore.load(forNodeID: node.id)
          ?? CopilotSessionLog.directory(forSessionNamed: name)?.lastPathComponent
      else { return nil }
      let directory = CopilotSessionLog.stateDirectory
        .appendingPathComponent(sessionID, isDirectory: true)
      let files = filesUnder(directory)
      guard !files.isEmpty else { return nil }
      return Artifact(
        backend: .copilotCLI, sessionID: sessionID,
        sourceWorkingDirectory: workingDirectory, files: files)

    case .codex:
      guard let url = CodexSessionLog.rollout(forWorkingDirectory: workingDirectory),
        let rollout = try? Data(contentsOf: url)
      else { return nil }
      return Artifact(
        backend: .codex, sessionID: url.lastPathComponent,
        sourceWorkingDirectory: workingDirectory,
        files: ["rollout.jsonl": rollout])

    case .openCode:
      // OpenCode's conversations live in one SQLite database shared by every session on
      // the machine, not in a file per session that can be lifted out. Its own
      // `opencode export` could produce one, but nothing imports it back into a *fresh*
      // identity, so an exported OpenCode loop starts fresh — as every Codex one does.
      return nil
    }
  }

  // MARK: - Remote export

  /// The remote twin of `exportArtifact`. A remote loop's session lives on the host it
  /// runs on — its id banked at the file `PresenceHooks.remoteSessionIDExpression`
  /// names, its transcript beside it — so reading this Mac's home directory found
  /// nothing and every remote export shipped without sessions (issue #333). The host
  /// locates the session and streams it back as `tar` on the ssh dial's stdout, the
  /// mirror of `restoreRemote`'s tar-in; the stream is unpacked here and re-keyed to
  /// exactly the artifact the local export produces, so `restore` and `restoreRemote`
  /// need no remote-aware branch of their own.
  ///
  /// Nil for anything short of a whole session: nothing banked, the files gone, the
  /// link dying mid-stream, the deadline (`remoteExportDeadlineSeconds`) passing. A loop
  /// whose fetch fails is exported without a session — the shape a local loop with
  /// nothing banked already has — never as a failed export.
  public static func exportRemoteArtifact(
    forNode node: LoopNode, at location: RemoteProjectLocation
  ) async -> Artifact? {
    guard let script = remoteExportScript(forNode: node, at: location) else { return nil }
    let staging = FileManager.default.temporaryDirectory
      .appendingPathComponent("graphcode-export-\(UUID().uuidString)", isDirectory: true)
    guard
      (try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true))
        != nil
    else { return nil }
    let status = remoteExportStatusFile(besideStaging: staging)
    defer {
      try? FileManager.default.removeItem(at: staging)
      try? FileManager.default.removeItem(at: status)
    }
    RemoteProjectLocation.prepareControlSocketDirectory()
    guard
      await runShell(remoteExportPipeline(remoteScript: script, staging: staging, at: location)),
      (try? String(contentsOf: status, encoding: .utf8)) == "0"
    else { return nil }
    return artifact(
      fromFetched: filesUnder(staging), backend: node.backend,
      workingDirectory: remoteWorkingDirectory(forNode: node, at: location))
  }

  /// The local half of the transfer: the dial's stdout straight into `tar -x`, so the
  /// bytes never pass through a PTY or a `String` — a transcript is arbitrary bytes at
  /// megabytes, the reason `deliver` is a pipeline too. Two verdicts, both required:
  /// the untar's, which is the pipeline's own status and rejects a stream the link
  /// truncated; and the dial's, recorded to a file beside the staging directory because
  /// a `tar -c` that lost a member mid-archive still emits a complete archive of the
  /// rest and exits non-zero — bytes plus a failure is a *partial* session, not one to
  /// carry (measured on the loopback rig, GNU and bsd tar alike). `gh codespace ssh`
  /// flattens every remote exit to 1, which is still non-zero, so the rule holds there.
  /// Recorded by a POSIX group rather than `set -o pipefail`, which `/bin/sh` is not
  /// guaranteed to know (dash rejects it and exits). A host that found nothing sends an
  /// empty stream and exits 0, which `tar` accepts and extracts nothing from — an empty
  /// staging directory is "nothing to carry", the local export's answer for a loop with
  /// nothing banked.
  static func remoteExportPipeline(
    remoteScript: String, staging: URL, at location: RemoteProjectLocation
  ) -> String {
    let status = RemoteProjectLocation.shellQuoted(
      remoteExportStatusFile(besideStaging: staging).path)
    let pipeline =
      "{ " + location.sshCommandLine(remoteCommand: remoteScript)
      + "; printf %s \"$?\" > \(status); }"
      + " | tar -xf - -C \(RemoteProjectLocation.shellQuoted(staging.path))"
    return bounded(pipeline, seconds: remoteExportDeadlineSeconds)
  }

  /// How long one loop's fetch may take before it is abandoned: generous enough for a
  /// stopped Codespace, which `gh` starts on the way in and which can take five minutes
  /// to deliver its first byte, and finite so that a live-but-silent remote or a wedged
  /// ssh master can never hang an export. On the deadline the loop is exported without
  /// a session, never as a failed export.
  static let remoteExportDeadlineSeconds = 600

  /// `pipeline` under a watchdog. Job control (`set -m`) puts the pipeline in a process
  /// group of its own, and the deadline kills that *group*: terminating only the shell
  /// would orphan `ssh` and `tar`, still joined by their pipe, holding the connection
  /// open for as long as the remote stayed silent. The watchdog's own group is killed
  /// on the way out so a fetch that finished in a second leaves no ten-minute `sleep`
  /// behind. Measured on a silent pipeline: dead at the deadline with exit 143 and no
  /// process left. `dash` runs this with job control off and a warning, so on a Linux
  /// host the deadline ends the wait but not the children — acceptable for the one
  /// caller, whose runner only ever runs on the Mac.
  ///
  /// The job's stdin is `/dev/null`, and that is load-bearing: a background process
  /// group that reads the controlling terminal is stopped with `SIGTTIN`, and `ssh`
  /// reads its inherited stdin. From the CLI in a Terminal that stdin *is* the tty, so
  /// without the redirect the dial stopped silently, the watchdog fired at the deadline,
  /// and the loop exported with no session (found in review; every measurement here had
  /// run without a tty). Nothing is ever sent to the host on this path.
  ///
  /// The trap is the other half of owning those groups: a signal to the shell alone —
  /// the app terminating the export, Ctrl-C in a Terminal, which reaches only the CLI's
  /// own group — would otherwise leave `ssh`, `tar`, the subshells and the ten-minute
  /// `sleep` running to the deadline (measured on the rig: all alive after the shell
  /// was TERMed). Both groups are killed and the shell exits 143, the status a TERM
  /// would have given it.
  static func bounded(_ pipeline: String, seconds: Int) -> String {
    "set -m; { \(pipeline); } </dev/null & gc_p=$!; "
      + "{ sleep \(seconds); kill -TERM -- -$gc_p; } 2>/dev/null & gc_w=$!; "
      + "trap 'kill -TERM -- -$gc_p -$gc_w 2>/dev/null; exit 143' INT TERM HUP; "
      + "wait $gc_p; gc_s=$?; kill -TERM -- -$gc_w 2>/dev/null; exit $gc_s"
  }

  /// Where the pipeline leaves the dial's exit status: beside the staging directory,
  /// never inside it, or `filesUnder` would carry it as part of the session.
  static func remoteExportStatusFile(besideStaging staging: URL) -> URL {
    URL(fileURLWithPath: staging.path + ".status")
  }

  /// What the host runs to find the loop's session and stream it out — the mirror of
  /// `remoteInstallScript`, and like it a pure function so its shape is testable. Each
  /// backend's lookup is the one graphcode already trusts elsewhere:
  ///
  /// - Claude Code: the banked id — the file the ensure's resume branch consumes — then
  ///   the transcript by id across every project directory, because a worktree-bound
  ///   loop's transcript lives under the worktree's slug (`findClaudeTranscript`).
  /// - Copilot: the banked id, else the directory whose `workspace.yaml` names the zmx
  ///   session graphcode launched it as — the walk `remoteIDBankFragment` does.
  /// - Codex: the newest rollout whose header opened in the loop's working directory,
  ///   the match `CodexSessionLog.remoteSummaryInvocation` makes.
  /// - OpenCode: nothing, for the reason the local export carries nothing.
  ///
  /// The archive's first path component is the session's identity — `<id>.jsonl`,
  /// `<id>/…`, `rollout-….jsonl` — which is how the id reaches this side without a
  /// second channel; `artifact(fromFetched:)` reads it back. A session that is not there
  /// exits 0 having written nothing. Not wrapped in the login shell the probes use: an
  /// interactive `zsh -i` may print from its rc files, and stdout here *is* the archive.
  static func remoteExportScript(
    forNode node: LoopNode, at location: RemoteProjectLocation
  ) -> String? {
    let idFile = PresenceHooks.remoteSessionIDExpression(forNodeID: node.id)
    switch node.backend {
    case .claudeCode:
      return "S=$(cat \(idFile) 2>/dev/null); [ -n \"$S\" ] || exit 0; "
        + "F=$(ls -t \"$HOME\"/.claude/projects/*/\"$S\".jsonl 2>/dev/null | head -1); "
        + "[ -n \"$F\" ] || exit 0; exec tar -cf - -C \"$(dirname \"$F\")\" \"$S.jsonl\""
    case .copilotCLI:
      let name = SurfaceRef(id: node.id, launchesClaudeCode: true).zmxSessionName
      return "S=$(cat \(idFile) 2>/dev/null); if [ -z \"$S\" ]; then "
        + "for d in $(ls -t \"$HOME/.copilot/session-state/\" 2>/dev/null); do "
        + "if grep -qx 'name: \(name)' "
        + "\"$HOME/.copilot/session-state/$d/workspace.yaml\" 2>/dev/null; "
        + "then S=\"$d\"; break; fi; done; fi; "
        + "[ -n \"$S\" ] && [ -d \"$HOME/.copilot/session-state/$S\" ] || exit 0; "
        + "exec tar -cf - -C \"$HOME/.copilot/session-state\" \"$S\""
    case .codex:
      let directory = RemoteProjectLocation.shellQuoted(
        remoteWorkingDirectory(forNode: node, at: location))
      return "W=\(directory); F=''; "
        + "for f in $(ls -t \"$HOME\"/.codex/sessions/*/*/*/rollout-*.jsonl 2>/dev/null"
        + " | head -40); do "
        + "if head -c 65536 \"$f\" 2>/dev/null | grep -q \"\\\"cwd\\\":\\\"$W\\\"\"; "
        + "then F=\"$f\"; break; fi; done; "
        + "[ -n \"$F\" ] || exit 0; exec tar -cf - -C \"$(dirname \"$F\")\" \"$(basename \"$F\")\""
    case .openCode:
      return nil
    }
  }

  /// A remote loop's working directory: its worktree if bound, else the project folder
  /// on that host — `CodexSessionLog.summary`'s answer, because the local one checks the
  /// path exists on this Mac and a remote one never does.
  static func remoteWorkingDirectory(
    forNode node: LoopNode, at location: RemoteProjectLocation
  ) -> String {
    node.worktreeBinding?.worktreePath ?? location.remotePath
  }

  /// The fetched archive as the artifact the *local* export would have produced for the
  /// same session — same keys, same id, so nothing downstream can tell where a session
  /// came from. The first path component carries the identity: for Claude and Codex a
  /// single file named by it, for Copilot the session directory, stripped from every key.
  /// Anything else — two transcripts, a stray file beside the directory — is not a
  /// session this side knows how to restore, and is refused rather than guessed at.
  static func artifact(
    fromFetched files: [String: Data], backend: CLISessionBackendKind, workingDirectory: String
  ) -> Artifact? {
    switch backend {
    case .claudeCode:
      guard let only = singleFile(in: files) else { return nil }
      return Artifact(
        backend: .claudeCode, sessionID: String(only.name.dropLast(".jsonl".count)),
        sourceWorkingDirectory: workingDirectory, files: ["transcript.jsonl": only.data])
    case .copilotCLI:
      guard let first = files.keys.sorted().first, let slash = first.firstIndex(of: "/")
      else { return nil }
      let sessionID = String(first[..<slash])
      let prefix = sessionID + "/"
      var relative: [String: Data] = [:]
      for (path, data) in files where path.hasPrefix(prefix) {
        relative[String(path.dropFirst(prefix.count))] = data
      }
      guard !relative.isEmpty, relative.count == files.count else { return nil }
      return Artifact(
        backend: .copilotCLI, sessionID: sessionID,
        sourceWorkingDirectory: workingDirectory, files: relative)
    case .codex:
      guard let only = singleFile(in: files) else { return nil }
      return Artifact(
        backend: .codex, sessionID: only.name,
        sourceWorkingDirectory: workingDirectory, files: ["rollout.jsonl": only.data])
    case .openCode:
      return nil
    }
  }

  private static func singleFile(in files: [String: Data]) -> (name: String, data: Data)? {
    guard files.count == 1, let entry = files.first, !entry.key.contains("/"),
      entry.key.hasSuffix(".jsonl")
    else { return nil }
    return (entry.key, entry.value)
  }

  // MARK: - Restore

  /// Installs an exported session for a freshly imported node, under a fresh identity,
  /// and — where the backend can resume — banks the fresh id so the existing resume
  /// machinery (`SessionIDStore` → `--resume`) continues the conversation the first
  /// time the loop's session starts.
  ///
  /// Ids are rewritten rather than reused: importing a bundle back into its source
  /// project would otherwise leave two loops banked against one conversation, both
  /// appending to it.
  ///
  /// Returns the fresh session id, or nil when nothing was installed (remote target —
  /// which `restoreRemote` handles instead — empty artifact, unwritable destination).
  /// Codex returns nil by design — its rollout is installed for `codex`'s own history
  /// pickers, but nothing is banked because nothing graphcode launches can resume it.
  @discardableResult
  public static func restore(
    _ artifact: Artifact, forNodeID nodeID: UUID, projectPath: String
  ) -> String? {
    guard !artifact.files.isEmpty else { return nil }
    // A remote project's sessions live on the remote machine; state written into this
    // Mac's home directory would never be found there. `restoreRemote` is the path
    // that reaches that machine.
    guard RemoteProjectLocation.parse(projectPath: projectPath) == nil else { return nil }

    switch artifact.backend {
    case .claudeCode: return restoreClaude(artifact, forNodeID: nodeID, projectPath: projectPath)
    case .copilotCLI: return restoreCopilot(artifact, forNodeID: nodeID)
    case .codex: return restoreCodex(artifact, projectPath: projectPath)
    case .openCode: return nil
    }
  }

  private static func restoreClaude(
    _ artifact: Artifact, forNodeID nodeID: UUID, projectPath: String
  ) -> String? {
    guard let transcript = artifact.files["transcript.jsonl"] else { return nil }
    let freshID = UUID().uuidString.lowercased()
    let directory =
      claudeProjectsRoot
      .appendingPathComponent(claudeProjectSlug(forWorkingDirectory: projectPath))
    guard
      write(
        rewriting(transcript, replacing: artifact.sessionID, with: freshID),
        to: directory.appendingPathComponent("\(freshID).jsonl"))
    else { return nil }
    SessionIDStore.save(freshID, forNodeID: nodeID)
    return freshID
  }

  private static func restoreCopilot(_ artifact: Artifact, forNodeID nodeID: UUID) -> String? {
    let freshID = UUID().uuidString.lowercased()
    let directory = CopilotSessionLog.stateDirectory
      .appendingPathComponent(freshID, isDirectory: true)
    for (relativePath, data) in artifact.files {
      guard
        write(
          rewriting(data, replacing: artifact.sessionID, with: freshID),
          to: directory.appendingPathComponent(relativePath))
      else { return nil }
    }
    SessionIDStore.save(freshID, forNodeID: nodeID)
    return freshID
  }

  // MARK: - Remote restore

  /// The remote twin of `restore`: installs the exported session on the host the
  /// imported loop will actually run on, and banks the fresh id at the exact file the
  /// daemon's ensure resume branch consumes (`PresenceHooks.remoteSessionIDExpression`)
  /// — so the first ensure after import runs `--resume` against the delivered
  /// transcript instead of starting fresh.
  ///
  /// Runs *before* the import command is sent, like the local restore: the node does
  /// not exist in any graph yet, so no ensure can race a half-delivered transcript.
  /// The transfer is one local pipeline — `tar` of the rewritten files piped into the
  /// host's own untar over the ssh dial — because the transcript is arbitrary bytes at
  /// transcript size: megabytes don't fit in an argv, and a PTY-backed runner would
  /// mangle them in transit. The id file is written last, only after the untar
  /// succeeded, so a delivery that died mid-transfer banks nothing and the loop falls
  /// through to today's fresh start.
  ///
  /// Codex and OpenCode return nil for the same reasons they bank nothing locally.
  @discardableResult
  public static func restoreRemote(
    _ artifact: Artifact, forNodeID nodeID: UUID, at location: RemoteProjectLocation
  ) async -> String? {
    guard !artifact.files.isEmpty else { return nil }
    let freshID = UUID().uuidString.lowercased()
    guard
      let script = remoteInstallScript(
        for: artifact, freshID: freshID, nodeID: nodeID, at: location)
    else { return nil }
    var staged: [String: Data] = [:]
    switch artifact.backend {
    case .claudeCode:
      guard let transcript = artifact.files["transcript.jsonl"] else { return nil }
      staged["\(freshID).jsonl"] =
        rewriting(transcript, replacing: artifact.sessionID, with: freshID)
    case .copilotCLI:
      for (relativePath, data) in artifact.files {
        staged[relativePath] = rewriting(data, replacing: artifact.sessionID, with: freshID)
      }
    case .codex, .openCode:
      return nil
    }
    guard await deliver(files: staged, remoteScript: script, at: location) else { return nil }
    return freshID
  }

  /// What the remote host runs while the tar stream arrives on its stdin: make the
  /// destination, untar into it, then bank the fresh id. One script, ordered so the
  /// bank write cannot precede the bytes it points at.
  ///
  /// Claude's destination is the slug of the session's *resolved* working directory,
  /// and only the remote host can resolve its own paths (`/tmp` is `/private/tmp` on a
  /// Mac and itself on Linux) — so the slug is computed there, with the same
  /// every-non-alphanumeric-becomes-`-` rule `claudeProjectSlug` applies locally.
  static func remoteInstallScript(
    for artifact: Artifact, freshID: String, nodeID: UUID, at location: RemoteProjectLocation
  ) -> String? {
    let bank =
      "printf %s '\(freshID)' > \"$HOME/.graphcode/sessions/\(nodeID.uuidString).id\""
    switch artifact.backend {
    case .claudeCode:
      let repo = RemoteProjectLocation.shellQuoted(location.remotePath)
      return "set -e; slug=$(cd \(repo) && printf %s \"$(pwd -P)\" "
        + "| LC_ALL=C tr -c '[:alnum:]' '-'); "
        + "dir=\"$HOME/.claude/projects/$slug\"; "
        + "mkdir -p \"$dir\" \"$HOME/.graphcode/sessions\"; "
        + "tar -xf - -C \"$dir\"; \(bank)"
    case .copilotCLI:
      return "set -e; dir=\"$HOME/.copilot/session-state/\(freshID)\"; "
        + "mkdir -p \"$dir\" \"$HOME/.graphcode/sessions\"; "
        + "tar -xf - -C \"$dir\"; \(bank)"
    case .codex, .openCode:
      return nil
    }
  }

  /// Stages the files in a temporary directory and streams them to the host as one
  /// `tar | ssh` pipeline. The pipeline's exit status is the ssh side's, which is the
  /// remote script's — `set -e` there turns any failed step into a failed delivery.
  private static func deliver(
    files: [String: Data], remoteScript: String, at location: RemoteProjectLocation
  ) async -> Bool {
    let staging = FileManager.default.temporaryDirectory
      .appendingPathComponent("graphcode-transplant-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: staging) }
    for (relativePath, data) in files {
      guard write(data, to: staging.appendingPathComponent(relativePath)) else { return false }
    }
    RemoteProjectLocation.prepareControlSocketDirectory()
    let pipeline =
      "tar -C \(RemoteProjectLocation.shellQuoted(staging.path)) -cf - . | "
      + location.sshCommandLine(remoteCommand: remoteScript)
    return await runShell(pipeline)
  }

  private static func runShell(_ script: String) async -> Bool {
    await withCheckedContinuation { continuation in
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/sh")
      process.arguments = ["-c", script]
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      process.terminationHandler = { continuation.resume(returning: $0.terminationStatus == 0) }
      do {
        try process.run()
      } catch {
        process.terminationHandler = nil
        continuation.resume(returning: false)
      }
    }
  }

  private static func restoreCodex(_ artifact: Artifact, projectPath: String) -> String? {
    guard let rollout = artifact.files["rollout.jsonl"] else { return nil }
    // Embedded cwd rewritten to the target project so Codex's own session pickers
    // list it under the project the loop now belongs to.
    var rewritten = rollout
    if let source = artifact.sourceWorkingDirectory {
      rewritten = rewriting(rewritten, replacing: source, with: projectPath)
    }
    let freshName = artifact.sessionID.replacingOccurrences(
      of: rolloutUUID(in: artifact.sessionID) ?? "", with: UUID().uuidString.lowercased())
    _ = write(rewritten, to: codexImportDirectory.appendingPathComponent(freshName))
    return nil
  }

  // MARK: - Backend layouts

  static var claudeProjectsRoot: URL {
    URL(fileURLWithPath: NSHomeDirectory())
      .appendingPathComponent(".claude", isDirectory: true)
      .appendingPathComponent("projects", isDirectory: true)
  }

  /// Where imported Codex rollouts land: a dated directory like the ones `codex`
  /// itself writes, under today's date at import time.
  static var codexImportDirectory: URL {
    let parts = Calendar(identifier: .gregorian)
      .dateComponents([.year, .month, .day], from: Date())
    return CodexSessionLog.sessionsDirectory
      .appendingPathComponent(String(parts.year ?? 1970), isDirectory: true)
      .appendingPathComponent(String(format: "%02d", parts.month ?? 1), isDirectory: true)
      .appendingPathComponent(String(format: "%02d", parts.day ?? 1), isDirectory: true)
  }

  /// Claude Code's directory name for a working directory: the *resolved* path with
  /// every non-alphanumeric character replaced by `-`. Resolution matters — a session
  /// started in `/tmp/x` is recorded under `-private-tmp-x` — and it has to be POSIX
  /// `realpath`, because Foundation's `resolvingSymlinksInPath()` deliberately leaves
  /// `/private` prefixes unresolved and produced the wrong directory for exactly
  /// those paths.
  static func claudeProjectSlug(forWorkingDirectory path: String) -> String {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    let resolved = path.withCString { realpath($0, &buffer).map { String(cString: $0) } } ?? path
    return String(resolved.map { $0.isLetter || $0.isNumber ? $0 : "-" })
  }

  private static func findClaudeTranscript(sessionID: String) -> URL? {
    // Found by id across every project directory rather than by reconstructing which
    // directory the session ran in — a loop bound to a worktree recorded its
    // transcript under the worktree's slug, not the project's, and the id is unique
    // either way.
    let fileManager = FileManager.default
    guard
      let projectDirs = try? fileManager.contentsOfDirectory(
        at: claudeProjectsRoot, includingPropertiesForKeys: nil)
    else { return nil }
    for directory in projectDirs {
      let candidate = directory.appendingPathComponent("\(sessionID).jsonl")
      if fileManager.fileExists(atPath: candidate.path) { return candidate }
    }
    return nil
  }

  /// The `<uuid>` inside a `rollout-<timestamp>-<uuid>.jsonl` filename.
  private static func rolloutUUID(in filename: String) -> String? {
    let stem = filename.hasSuffix(".jsonl") ? String(filename.dropLast(6)) : filename
    let tail = stem.split(separator: "-").suffix(5).joined(separator: "-")
    return UUID(uuidString: tail) != nil ? tail : nil
  }

  // MARK: - File plumbing

  private static func filesUnder(_ root: URL) -> [String: Data] {
    var files: [String: Data] = [:]
    let fileManager = FileManager.default
    guard
      let enumerator = fileManager.enumerator(
        at: root, includingPropertiesForKeys: [.isRegularFileKey])
    else { return files }
    // Resolved on both sides before the prefix strip, or a symlinked component
    // (`/var` → `/private/var`) turns every relative key into an absolute path.
    let rootPrefix = root.resolvingSymlinksInPath().path + "/"
    for case let url as URL in enumerator {
      guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
      else { continue }
      let resolved = url.resolvingSymlinksInPath().path
      guard resolved.hasPrefix(rootPrefix) else { continue }
      if let data = try? Data(contentsOf: url) {
        files[String(resolved.dropFirst(rootPrefix.count))] = data
      }
    }
    return files
  }

  /// Text files get the old identity swapped for the new; anything that doesn't
  /// decode as UTF-8 passes through untouched rather than being corrupted by a
  /// byte-level splice.
  private static func rewriting(_ data: Data, replacing old: String, with new: String) -> Data {
    guard let text = String(data: data, encoding: .utf8) else { return data }
    return Data(text.replacingOccurrences(of: old, with: new).utf8)
  }

  private static func write(_ data: Data, to url: URL) -> Bool {
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: url, options: .atomic)
      return true
    } catch {
      return false
    }
  }
}
