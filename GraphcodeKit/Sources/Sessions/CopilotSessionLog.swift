import Foundation

/// Copilot CLI's presence, read out of the event log it already writes.
///
/// Copilot is the one spiked backend with no hook mechanism at all — nothing in
/// `copilot --help` installs a lifecycle handler, which is why
/// `BackendCapabilities.supportsHooks` is false for it and stays false. So its presence
/// comes from the other end: every session writes
/// `~/.copilot/session-state/<id>/events.jsonl` as it runs, and that file marks turn
/// boundaries explicitly — `assistant.turn_start`, `assistant.turn_end`,
/// `permission.requested` — where Claude Code's transcript only implies them through a
/// `stop_reason`. Nothing has to be inferred here; the events say it.
///
/// This is the "OSC scanning" tier of docs/04-cli-backends.md#presence in everything but
/// mechanism: a reading the backend didn't volunteer, taken from outside, and reported at
/// `.scanned` confidence so a human deciding whether to intervene can tell it from a fact
/// the agent reported about itself.
public enum CopilotSessionLog {
  /// Where Copilot keeps one directory per session. A `var` only so tests can point it at
  /// a fixture; nothing in the app writes it.
  public static var stateDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".copilot/session-state", isDirectory: true)

  /// How much of the tail is enough to find the last state-changing event.
  ///
  /// The log grows with the conversation — a long session's is megabytes — and the answer
  /// is always within the last few records. Read from the end rather than parsed whole,
  /// because this runs for every Copilot node on every usage poll.
  static let tailBytes = 64 * 1024

  /// Which events mean what. Events not listed (`assistant.message`, the `session.*`
  /// bookkeeping, `system.*`) are deliberately absent rather than mapped to something
  /// plausible: they can land after a turn ends, and treating a usage checkpoint as work
  /// would put a card back to claiming activity that isn't happening.
  ///
  /// **`session.start` is not on the list, and that was measured rather than reasoned.** A
  /// Copilot session parked at its trust-this-folder dialog — the failure
  /// `BackendCommand.permissionArguments` describes, and one this reading ought to make
  /// visible — has written exactly `session.start` and nothing since. Calling that busy
  /// reports a session sitting at a prompt nobody is watching as a loop hard at work,
  /// which is the original lie with a new source. Unlisted, it falls through to idle at
  /// `.heuristic`: "a live session with nothing happening", which is what it is.
  static func presence(forEvent event: String) -> Presence? {
    switch event {
    case "user.message", "assistant.turn_start",
      "tool.execution_start", "tool.execution_complete", "permission.completed":
      return .busy
    case "permission.requested", "assistant.turn_end":
      return .awaitingInput
    case "session.shutdown":
      return .absent
    default:
      return nil
    }
  }

  /// The session directory Copilot wrote for this node, found by the name graphcode gave
  /// it at launch (`--name`, see `CLISessionBackendKind.presenceArguments`).
  ///
  /// Newest first, and the first match wins: relaunching a node's session inside its
  /// still-live `zmx` window makes a *second* directory with the same name, and the one
  /// that matters is the one being written to now.
  static func directory(forSessionNamed name: String) -> URL? {
    let manager = FileManager.default
    guard
      let entries = try? manager.contentsOfDirectory(
        at: stateDirectory, includingPropertiesForKeys: [.contentModificationDateKey])
    else { return nil }
    let newestFirst = entries.sorted { left, right in
      let leftDate =
        (try? left.resourceValues(forKeys: [.contentModificationDateKey]))?
        .contentModificationDate ?? .distantPast
      let rightDate =
        (try? right.resourceValues(forKeys: [.contentModificationDateKey]))?
        .contentModificationDate ?? .distantPast
      return leftDate > rightDate
    }
    return newestFirst.first { names($0) == name }
  }

  /// The `name:` line out of a session's `workspace.yaml`. Matched on the whole key rather
  /// than a suffix, because `client_name:` sits two lines above it and ends the same way.
  static func names(_ directory: URL) -> String? {
    guard
      let contents = try? String(
        contentsOf: directory.appendingPathComponent("workspace.yaml"), encoding: .utf8)
    else { return nil }
    for line in contents.split(separator: "\n") where line.hasPrefix("name: ") {
      return String(line.dropFirst("name: ".count)).trimmingCharacters(in: .whitespaces)
    }
    return nil
  }

  /// What one `tool.execution_start` record is doing, in the same voice as Claude Code's
  /// hook script — `editing Foo.swift`, `running make check`.
  ///
  /// Copilot's own `description` argument is preferred where it exists, because it is a
  /// sentence a model wrote to explain the call rather than one assembled here from a
  /// tool name. An unknown tool falls through to its own name rather than being dropped:
  /// "using fetch" is worth more than silence, and the tool vocabulary is the backend's
  /// to change without notice.
  static func phrase(forTool name: String, arguments: [String: Any]) -> String? {
    func text(_ key: String) -> String? {
      guard let raw = arguments[key] as? String else { return nil }
      let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    func leaf(_ key: String) -> String? {
      text(key).map { String($0.split(separator: "/").last ?? Substring($0)) }
    }
    let specific: String?
    switch name {
    case "bash", "shell":
      specific = (text("description") ?? text("command")).map { "running \($0)" }
    case "view", "read":
      specific = leaf("path").map { "reading \($0)" }
    case "create", "edit", "str_replace_editor", "write":
      specific = leaf("path").map { "editing \($0)" }
    case "grep", "search":
      specific = text("pattern").map { "searching for \($0)" }
    case "glob":
      specific = text("pattern").map { "looking for \($0)" }
    case "fetch":
      specific = text("url").map { "reading \($0)" }
    default:
      specific = nil
    }
    // A recognised tool whose arguments aren't the shape expected falls back rather than
    // vanishing: the backend can rename an argument without warning, and "using view" is
    // worth more than a card that goes quiet mid-call.
    return specific ?? text("description") ?? "using \(name)"
  }

  /// The tool call this session is inside right now, or `nil` when it is between calls.
  ///
  /// Started-but-not-completed rather than simply "the last start": every call writes both
  /// a `tool.execution_start` and a `tool.execution_complete` carrying the same
  /// `toolCallId`, so the completions seen while walking backwards are what say which
  /// starts are already over. Reporting the last start regardless would leave a finished
  /// command on the card for the whole of the model's next think, which is the stale label
  /// this feature exists to remove.
  static func lastActivity(inLogAt url: URL) -> String? {
    var completed = Set<String>()
    for line in tailLines(ofLogAt: url).reversed() {
      guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
        let event = object as? [String: Any],
        let type = event["type"] as? String
      else { continue }
      let data = event["data"] as? [String: Any] ?? [:]
      let callID = data["toolCallId"] as? String
      switch type {
      case "tool.execution_complete":
        if let callID { completed.insert(callID) }
      case "tool.execution_start":
        guard let name = data["toolName"] as? String else { continue }
        if let callID, completed.contains(callID) { continue }
        let phrase = phrase(forTool: name, arguments: data["arguments"] as? [String: Any] ?? [:])
        return phrase.flatMap(ZmxSessionLauncher.condensedActivity)
      // A turn that has ended is not inside a tool call, whatever started before it.
      case "assistant.turn_end", "session.shutdown":
        return nil
      default:
        continue
      }
    }
    return nil
  }

  /// The tail of a log, as whole lines.
  ///
  /// The first line of a mid-file read is a fragment. It is dropped rather than repaired:
  /// one event's worth of tail is nowhere near the window this reads.
  static func tailLines(ofLogAt url: URL) -> [Substring] {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
    defer { try? handle.close() }
    guard let end = try? handle.seekToEnd() else { return [] }
    let start = end > UInt64(tailBytes) ? end - UInt64(tailBytes) : 0
    try? handle.seek(toOffset: start)
    guard let data = try? handle.readToEnd() else { return [] }
    var lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
    if start > 0, !lines.isEmpty { lines.removeFirst() }
    return lines
  }

  /// What this node's Copilot session is doing, or `nil` when nothing says.
  ///
  /// Local only, deliberately. The remote twin of this would have to carry a JSON record
  /// back through a shell pipeline, where `remotePresence` needs only an event name; that
  /// is a bigger change than this one and remote Copilot activity stays `nil` — which is
  /// what every Copilot node reported before this, so no reading gets worse.
  public static func activity(of node: LoopNode, projectPath: String? = nil) async -> String? {
    if let projectPath, RemoteProjectLocation.parse(projectPath: projectPath) != nil {
      return nil
    }
    let name = SurfaceRef(id: node.id, launchesClaudeCode: true).zmxSessionName
    guard ZmxLocator.isInstalled, await ZmxSessionLauncher.sessionExists(node),
      let directory = directory(forSessionNamed: name)
    else { return nil }
    return lastActivity(inLogAt: directory.appendingPathComponent("events.jsonl"))
  }

  /// Every beat in an event log's tail, oldest first.
  ///
  /// Copilot's `assistant.message` is the narration — the sentence it writes alongside the
  /// `toolRequests` it is about to make — and `user.message` is the pass boundary. Tool
  /// calls come through `phrase(forTool:arguments:)` unchanged, which means a beat's
  /// evidence prefers Copilot's own `description` exactly as the card's live line does.
  public static func beats(inLogAt url: URL) -> [SummaryBeat] {
    var builder = builder(inLogAt: url)
    return builder.beats()
  }

  /// The same read, as the reading the store merges — see `ClaudeSessionLog.reading`.
  static func reading(inLogAt url: URL, metricSamples: [MetricSample]) -> SummaryReading {
    var builder = builder(inLogAt: url)
    return SummaryBeatBuilder.reading(
      from: builder.beats(), turns: builder.userTurns(), metricSamples: metricSamples)
  }

  private static func builder(inLogAt url: URL) -> SummaryBeatBuilder {
    var builder = SummaryBeatBuilder()
    for line in SummaryBeatBuilder.tailLines(of: url) {
      guard let object = try? JSONSerialization.jsonObject(with: line),
        let event = object as? [String: Any],
        let type = event["type"] as? String
      else { continue }
      let data = event["data"] as? [String: Any] ?? [:]
      let at =
        SummaryBeatBuilder.date(fromTimestamp: event["timestamp"] ?? data["timestamp"]) ?? Date()
      switch type {
      case "user.message":
        builder.noteUserTurn(at: at)
      case "assistant.message":
        builder.noteNarration(data["content"] as? String ?? "", at: at)
      case "tool.execution_start":
        guard let name = data["toolName"] as? String,
          let phrase = phrase(
            forTool: name, arguments: data["arguments"] as? [String: Any] ?? [:])
        else { continue }
        builder.noteTool(phrase, at: at)
      // Copilot marks its turn boundaries outright, which is why its presence reader was
      // the one that never had to infer them.
      case "assistant.turn_end":
        builder.noteTurnEnd()
      default:
        continue
      }
    }
    return builder
  }

  /// What this node's Copilot session has been doing, or `nil` when nothing says. Local
  /// only, for the reason `activity` is.
  public static func summary(of node: LoopNode, projectPath: String? = nil) async
    -> SummaryReading?
  {
    if let projectPath, RemoteProjectLocation.parse(projectPath: projectPath) != nil {
      return nil
    }
    let name = SurfaceRef(id: node.id, launchesClaudeCode: true).zmxSessionName
    guard let directory = directory(forSessionNamed: name) else { return nil }
    let log = directory.appendingPathComponent("events.jsonl")
    guard await TranscriptFreshness.shared.hasChanged(log, forNode: node.id) else { return nil }
    let reading = reading(inLogAt: log, metricSamples: node.metricHistory)
    return reading.isEmpty ? nil : reading
  }

  /// The last event in a log that says anything about what the session is doing.
  static func lastStateChange(inLogAt url: URL) -> Presence? {
    for line in tailLines(ofLogAt: url).reversed() {
      guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
        let event = (object as? [String: Any])?["type"] as? String,
        let presence = presence(forEvent: event)
      else { continue }
      return presence
    }
    return nil
  }

  /// What this node's Copilot session is doing, or `.absent` when there is no live session
  /// or no log to read.
  ///
  /// The liveness check comes first and is not redundant with the log. A session killed
  /// outright leaves its log ending at whatever it was doing — usually `assistant.turn_end`
  /// — and reporting that as idle would describe a session that no longer exists as one
  /// quietly waiting for work.
  ///
  /// A remote Copilot's log lives on the remote host, so the probe SSHs in and reads it
  /// there — same event types, same mapping, expressed as grep/tail because it runs inside
  /// a remote shell. The earlier fallback to `ZmxSessionLauncher.presence` read zmx labels
  /// Copilot never writes, so remote Copilot nodes were permanently stuck at heuristic idle.
  public static func presence(of node: LoopNode, projectPath: String? = nil) async
    -> PresenceReading
  {
    if let projectPath, let remote = RemoteProjectLocation.parse(projectPath: projectPath) {
      return await remotePresence(of: node, at: remote)
    }
    let name = SurfaceRef(id: node.id, launchesClaudeCode: true).zmxSessionName
    guard ZmxLocator.isInstalled, await ZmxSessionLauncher.sessionExists(node) else {
      return .absent
    }
    guard let directory = directory(forSessionNamed: name),
      let presence = lastStateChange(
        inLogAt: directory.appendingPathComponent("events.jsonl"))
    else {
      // A live session graphcode can see but whose log it can't — a Copilot too old to
      // take `--name`, a session started before this shipped. Same answer the zmx path
      // gives when a label is missing, and flagged the same way.
      return PresenceReading(presence: .idle, confidence: .heuristic)
    }
    return PresenceReading(presence: presence, confidence: .scanned)
  }

  // MARK: - Remote

  /// Banks a live remote Copilot session's resume ID into
  /// `~/.graphcode/sessions/<node>.id` — the file every restorer already reads — from
  /// the outside, because Copilot has no hooks to bank it itself the way Claude's
  /// `SessionStart` does. Without this, a remote host reboot found nothing banked and
  /// every Copilot loop restarted its goal from scratch (observed 2026-08-13, the
  /// first dial-logged incident).
  ///
  /// The ID is the session-state directory's basename, found by the `--name` graphcode
  /// launched the session with — the same directory walk `remotePresenceInvocation`
  /// does, done here in the ensure's *alive* branch. The `[ -s ]` guard keeps the walk
  /// off the healthy tick once banked: it runs once per session lifetime. History line
  /// before pointer, same order and format as `PresenceHooks.captureSessionID`, and
  /// the whole fragment is silenced and `|| true`d so a banking failure can never turn
  /// an alive tick into the create branch.
  public static func remoteIDBankFragment(forNodeID nodeID: UUID) -> String {
    let name = SurfaceRef(id: nodeID, launchesClaudeCode: true).zmxSessionName
    let sessions = PresenceHooks.remoteSessionsExpression
    let idFile = PresenceHooks.remoteSessionIDExpression(forNodeID: nodeID)
    let historyFile = "\(sessions)/\"\(nodeID.uuidString).history\""
    let logged = DialLog.fragment(session: name, dial: "bank", event: "copilot-id")
    return "{ [ -s \(idFile) ] || { gc_sid=''; "
      + "for gc_d in $(ls -t \"$HOME/.copilot/session-state/\" 2>/dev/null); do "
      + "if grep -qx 'name: \(name)' "
      + "\"$HOME/.copilot/session-state/$gc_d/workspace.yaml\" 2>/dev/null; then "
      + "gc_sid=\"$gc_d\"; break; fi; done; "
      + "if [ -n \"$gc_sid\" ]; then mkdir -p \(sessions); "
      + "printf '%s %s %s\\n' \"$(date +%s)\" \"$gc_sid\" \"$PWD\" >> \(historyFile); "
      + "printf '%s' \"$gc_sid\" > \(idFile); \(logged); fi; }; } 2>/dev/null || true"
  }

  static func remotePresenceInvocation(
    forNode node: LoopNode, at location: RemoteProjectLocation
  ) -> [String] {
    let name = SurfaceRef(id: node.id, launchesClaudeCode: true).zmxSessionName
    let check = ZmxSessionLauncher.quotedCommand(["zmx", "get", name])
    let marker = ZmxSessionLauncher.remoteProbeMarker

    let findDir =
      "D=''; for d in $(ls -t \"$HOME/.copilot/session-state/\" 2>/dev/null); do "
      + "if grep -qx 'name: \(name)' \"$HOME/.copilot/session-state/$d/workspace.yaml\" 2>/dev/null; then "
      + "D=\"$HOME/.copilot/session-state/$d\"; break; fi; done"

    let readEvent =
      "E=$(tail -c 65536 \"$D/events.jsonl\" 2>/dev/null"
      + " | grep -o '\"type\":\"[^\"]*\"'"
      + " | grep -E 'user\\.message|assistant\\.turn_start|tool\\.execution_start|tool\\.execution_complete|permission\\.completed|permission\\.requested|assistant\\.turn_end|session\\.shutdown'"
      + " | tail -1 | sed 's/.*\"type\":\"//;s/\"//')"

    let script =
      "if \(check) >/dev/null 2>&1; then "
      + "\(findDir); "
      + "if [ -n \"$D\" ]; then \(readEvent); "
      + "echo \"\(marker) live copilot=$E\"; "
      + "else echo \"\(marker) live\"; fi; "
      + "else echo '\(marker) absent'; fi"

    return location.sshInvocation(
      remoteCommand: location.remoteLoginShellCommand(script))
  }

  static func remotePresence(
    of node: LoopNode, at location: RemoteProjectLocation
  ) async -> PresenceReading {
    RemoteProjectLocation.prepareControlSocketDirectory()
    let invocation = remotePresenceInvocation(forNode: node, at: location)
    guard
      let session = try? PTYProcessSession(
        executable: invocation[0], arguments: Array(invocation.dropFirst()))
    else { return .unknown }
    let (succeeded, output) = await session.waitCollectingOutput()
    return parseRemotePresence(succeeded: succeeded, output: output)
  }

  static func parseRemotePresence(succeeded: Bool, output: String) -> PresenceReading {
    let status = ZmxSessionLauncher.parseRemoteStatus(
      succeeded: succeeded, output: output)
    switch status {
    case .unreachable: return .unknown
    case .absent: return .absent
    case .live(let label):
      guard let label, let event = parseCopilotEventLabel(label),
        let p = presence(forEvent: event)
      else {
        return PresenceReading(presence: .idle, confidence: .heuristic)
      }
      return PresenceReading(presence: p, confidence: .scanned)
    }
  }

  static func parseCopilotEventLabel(_ label: String) -> String? {
    let trimmed = label.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("copilot=") else { return nil }
    let event = String(trimmed.dropFirst("copilot=".count))
    return event.isEmpty ? nil : event
  }
}
