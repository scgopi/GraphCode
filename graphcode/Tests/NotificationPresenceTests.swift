import ComposableArchitecture
import Foundation
import GraphcodeKit
import Testing

@testable import GraphcodeKit

/// Issue #306: Claude Code fires a `Notification` about a minute after a turn ends —
/// `idle_prompt`, "still idle" — and graphcode mapped every notification to
/// `awaitingInput`. So every resting loop flipped to *needs a human* sixty seconds after
/// it stopped, and since staged follow-ups and Mailroom wakes deliver only on `idle`,
/// they never arrived (0 of 18 measured). The reporter now reads the kind, and errs
/// towards `awaitingInput` for anything it cannot classify: a loop that genuinely asked
/// a question must never become invisible.
@Suite
struct NotificationPresenceTests {
  /// Runs the generated reporter the way Claude Code runs it — `/bin/sh`, the payload on
  /// stdin — against a `zmx` that records what it was asked to set. The labels it set,
  /// or empty if it set nothing.
  private func labels(for payload: String, session: String = "graphcode-test") throws
    -> [String]
  {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("graphcode-notification-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let recording = directory.appendingPathComponent("set.txt")
    let fakeZmx = directory.appendingPathComponent("zmx")
    try "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '\(recording.path)'\n"
      .write(to: fakeZmx, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: fakeZmx.path)
    let script = directory.appendingPathComponent("notification.sh")
    try PresenceHooks.notificationScript(zmxPath: fakeZmx.path)
      .write(to: script, atomically: true, encoding: .utf8)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [script.path]
    process.environment = ["ZMX_SESSION": session, "PATH": "/usr/bin:/bin"]
    let input = Pipe()
    process.standardInput = input
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    input.fileHandleForWriting.write(Data(payload.utf8))
    try input.fileHandleForWriting.close()
    process.waitUntilExit()
    // Never non-zero: a failing hook prints over the human's own session.
    #expect(process.terminationStatus == 0)
    guard let recorded = try? String(contentsOf: recording, encoding: .utf8) else { return [] }
    return recorded.split(separator: "\n").map(String.init)
  }

  private func payload(kind: String?) -> String {
    let type = kind.map { "\"notification_type\":\"\($0)\"," } ?? ""
    return """
      {"session_id":"a","cwd":"/w","hook_event_name":"Notification",\(type)\
      "message":"Claude is waiting for your input","title":"Claude Code"}
      """
  }

  private func presence(_ labels: [String]) -> Presence? {
    guard let line = labels.last else { return nil }
    let label = line.split(separator: " ").first { $0.hasPrefix("presence=") }
    return label.flatMap { Presence(rawValue: String($0.dropFirst("presence=".count))) }
  }

  @Test
  func anIdlePromptConfirmsIdleAndClearsTheActivity() throws {
    let set = try labels(for: payload(kind: "idle_prompt"))
    #expect(presence(set) == .idle)
    #expect(set.last?.contains(" activity=") == true)
    #expect(set.last?.hasPrefix("set graphcode-test ") == true)
  }

  @Test
  func aRealPromptToTheHumanIsAwaitingInput() throws {
    #expect(try presence(labels(for: payload(kind: "permission_prompt"))) == .awaitingInput)
    #expect(try presence(labels(for: payload(kind: "elicitation_dialog"))) == .awaitingInput)
  }

  /// The mirror of the bug, refused: a kind this build does not know, or no kind at all
  /// from a Claude Code that predates the field, keeps today's behaviour — never idle.
  @Test
  func anUnknownOrAbsentKindKeepsTodaysBehaviour() throws {
    #expect(try presence(labels(for: payload(kind: "something_newer"))) == .awaitingInput)
    #expect(try presence(labels(for: payload(kind: nil))) == .awaitingInput)
  }

  @Test
  func anAuthSuccessSaysNothingAboutPresence() throws {
    #expect(try labels(for: payload(kind: "auth_success")).isEmpty)
  }

  @Test
  func aSessionGraphcodeDidNotStartIsLeftAlone() throws {
    #expect(try labels(for: payload(kind: "idle_prompt"), session: "").isEmpty)
  }

  /// The hook file runs the reporter, and falls back to today's report — not to
  /// nothing — when the reporter is missing.
  @Test
  func theHookRunsTheReporterAndFallsBackToAwaitingInput() throws {
    let json = try #require(
      PresenceHooks.json(
        forBackend: .claudeCode, zmxPath: "/opt/zmx", notificationScriptPath: "'/hooks/n.sh'"))
    let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
    let hooks = try #require(object?["hooks"] as? [String: Any])
    let notification = try #require(hooks["Notification"] as? [[String: Any]])
    let commands = try #require(notification.first?["hooks"] as? [[String: Any]])
    let command = try #require(commands.first?["command"] as? String)
    #expect(command.hasPrefix("if [ -r '/hooks/n.sh' ]; then /bin/sh '/hooks/n.sh'; else "))
    #expect(command.contains("presence=awaitingInput activity="))
    #expect(command.hasSuffix("; fi; exit 0"))
    // Every other event still reports its fixed presence.
    let stop = try #require(
      (hooks["Stop"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])
    #expect((stop.first?["command"] as? String)?.contains("presence=idle") == true)
    // And the remote host is handed the reporter beside the settings that name it.
    let fragment = try #require(PresenceHooks.remoteWriteFragment(forBackend: .claudeCode))
    #expect(fragment.contains("notification.sh"))
    #expect(fragment.contains("idle_prompt) presence=idle"))
  }

  /// The whole path, the way MailWatcher measured it: a loop that has been idle past the
  /// notification receives the Mailroom wake and the `--follow-up` staged for it — on
  /// exactly the presence the reporter writes for `idle_prompt`, and not on the one it
  /// writes for a permission prompt.
  @Test
  func aLoopIdlePastTheNotificationReceivesItsWakeAndItsFollowUp() async throws {
    let afterIdlePrompt = try #require(presence(labels(for: payload(kind: "idle_prompt"))))
    let afterPermission = try #require(
      presence(labels(for: payload(kind: "permission_prompt"))))

    actor Readings {
      var presence: Presence = .busy
      func set(_ presence: Presence) { self.presence = presence }
      func read() -> PresenceReading { PresenceReading(presence: presence, confidence: .reported) }
    }
    let readings = Readings()
    let delivered = LockIsolated<[String]>([])
    let store = GraphStore(
      onEnsureSession: { _, _ in },
      onDeliverMessage: { _, message, _ in
        delivered.withValue { $0.append(message) }
        return true
      },
      onReadPresence: { _, _ in await readings.read() },
      onMailroomEnabled: { true })
    await store.handle(
      .createNode(NodeDraft(title: "Watcher", loopType: .turnBased, firstInstruction: "Work")))
    await store.handle(
      .createNode(NodeDraft(title: "Poster", loopType: .turnBased, firstInstruction: "Work")))
    let ids = await store.graph.nodes.map(\.id)
    // A connection so the poll runs, with a channel lifecycle of its own and a reader
    // draining it: a bare `/dev/null` descriptor can be dropped as "disconnected" when
    // its number is reused across the suite, and then the poll never drains.
    var pair: [Int32] = [0, 0]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
    let drainer = Task.detached {
      var sink = [UInt8](repeating: 0, count: 65536)
      while recv(pair[1], &sink, sink.count, 0) > 0 {}
    }
    defer {
      OutboundChannels.close(pair[0])
      close(pair[1])
      drainer.cancel()
    }
    await store.addConnection(id: UUID(), fileDescriptor: pair[0])
    await store.pollPresence()
    await store.handle(.mailroomWatch(on: true, topic: "e2e", from: ids[0]))
    await store.handle(.mailroomPost(text: "matching post", topic: "e2e", from: ids[1]))
    await store.handle(.messageNode(ids[0], text: "a follow-up", from: ids[1], followUp: true))
    #expect(delivered.value.isEmpty)

    // Sixty seconds later, the old mapping: the loop reads as needing a human, and the
    // drain — which this state was chosen to gate — hands over nothing.
    await readings.set(afterPermission)
    await store.pollPresence()
    #expect(delivered.value.isEmpty)

    // The new mapping of the same idle notification: still idle, and both arrive.
    await readings.set(afterIdlePrompt)
    await store.pollPresence()
    #expect(delivered.value.count == 2)
    #expect(delivered.value.contains { $0.contains("new post #1") })
    #expect(delivered.value.contains { $0.contains("a follow-up") })
  }
}
