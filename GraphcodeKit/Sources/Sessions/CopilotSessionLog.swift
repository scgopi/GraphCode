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

  /// The last event in a log that says anything about what the session is doing.
  static func lastStateChange(inLogAt url: URL) -> Presence? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard let end = try? handle.seekToEnd() else { return nil }
    let start = end > UInt64(tailBytes) ? end - UInt64(tailBytes) : 0
    try? handle.seek(toOffset: start)
    guard let data = try? handle.readToEnd() else { return nil }

    // The first line of a mid-file read is a fragment. It is dropped rather than repaired:
    // one event's worth of tail is nowhere near the window this reads.
    var lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
    if start > 0, !lines.isEmpty { lines.removeFirst() }

    for line in lines.reversed() {
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
